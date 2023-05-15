package PVE::API2::TFA;

use strict;
use warnings;

use HTTP::Status qw(:constants);

use PVE::AccessControl;
use PVE::Cluster qw(cfs_read_file cfs_write_file);
use PVE::Exception qw(raise raise_perm_exc raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;
use PVE::SafeSyslog;

use PVE::API2::AccessControl; # for old login api get_u2f_instance method

use PVE::RESTHandler;

use base qw(PVE::RESTHandler);

my $OPTIONAL_PASSWORD_SCHEMA = {
    description => "The current password.",
    type => 'string',
    optional => 1, # Only required if not root@pam
    minLength => 5,
    maxLength => 64
};

my $TFA_TYPE_SCHEMA = {
    type => 'string',
    description => 'TFA Entry Type.',
    enum => [qw(totp u2f webauthn recovery yubico)],
};

my %TFA_INFO_PROPERTIES = (
    id => {
	type => 'string',
	description => 'The id used to reference this entry.',
    },
    description => {
	type => 'string',
	description => 'User chosen description for this entry.',
    },
    created => {
	type => 'integer',
	description => 'Creation time of this entry as unix epoch.',
    },
    enable => {
	type => 'boolean',
	description => 'Whether this TFA entry is currently enabled.',
	optional => 1,
	default => 1,
    },
);

my $TYPED_TFA_ENTRY_SCHEMA = {
    type => 'object',
    description => 'TFA Entry.',
    properties => {
	type => $TFA_TYPE_SCHEMA,
	%TFA_INFO_PROPERTIES,
    },
};

my $TFA_ID_SCHEMA = {
    type => 'string',
    description => 'A TFA entry id.',
};

my $TFA_UPDATE_INFO_SCHEMA = {
    type => 'object',
    properties => {
	id => {
	    type => 'string',
	    description => 'The id of a newly added TFA entry.',
	},
	challenge => {
	    type => 'string',
	    optional => 1,
	    description =>
		'When adding u2f entries, this contains a challenge the user must respond to in order'
		.' to finish the registration.'
	},
	recovery => {
	    type => 'array',
	    optional => 1,
	    description =>
		'When adding recovery codes, this contains the list of codes to be displayed to'
		.' the user',
	    items => {
		type => 'string',
		description => 'A recovery entry.'
	    },
	},
    },
};

# Only root may modify root, regular users need to specify their password.
#
# Returns the userid returned from `verify_username`.
# Or ($userid, $realm) in list context.
my sub root_permission_check : prototype($$$$) {
    my ($rpcenv, $authuser, $userid, $password) = @_;

    ($userid, undef, my $realm) = PVE::AccessControl::verify_username($userid);
    $rpcenv->check_user_exist($userid);

    raise_perm_exc() if $userid eq 'root@pam' && $authuser ne 'root@pam';

    # Regular users need to confirm their password to change TFA settings.
    if ($authuser ne 'root@pam') {
	raise_param_exc({ 'password' => 'password is required to modify TFA data' })
	    if !defined($password);

	($authuser, my $auth_username, my $auth_realm) =
	    PVE::AccessControl::verify_username($authuser);

	my $domain_cfg = cfs_read_file('domains.cfg');
	my $cfg = $domain_cfg->{ids}->{$auth_realm};
	die "auth domain '$auth_realm' does not exist\n" if !$cfg;
	my $plugin = PVE::Auth::Plugin->lookup($cfg->{type});
	$plugin->authenticate_user($cfg, $auth_realm, $auth_username, $password);
    }

    return wantarray ? ($userid, $realm) : $userid;
}

# Set TFA to enabled if $tfa_cfg is passed, or to disabled if $tfa_cfg is undef,
# When enabling we also merge the old user.cfg keys into the $tfa_cfg.
my sub set_user_tfa_enabled : prototype($$$) {
    my ($userid, $realm, $tfa_cfg) = @_;

    PVE::AccessControl::lock_user_config(sub {
	my $user_cfg = cfs_read_file('user.cfg');
	my $user = $user_cfg->{users}->{$userid};
	my $keys = $user->{keys};
	# When enabling, we convert old-old keys,
	# When disabling, we shouldn't actually have old keys anymore, so if they are there,
	# they'll be removed.
	if ($tfa_cfg && $keys && $keys !~ /^x(?:!.*)?$/) {
	    my $domain_cfg = cfs_read_file('domains.cfg');
	    my $realm_cfg = $domain_cfg->{ids}->{$realm};
	    die "auth domain '$realm' does not exist\n" if !$realm_cfg;

	    my $realm_tfa = $realm_cfg->{tfa};
	    $realm_tfa = PVE::Auth::Plugin::parse_tfa_config($realm_tfa) if $realm_tfa;

	    PVE::AccessControl::add_old_keys_to_realm_tfa($userid, $tfa_cfg, $realm_tfa, $keys);
	}
	$user->{keys} = $tfa_cfg ? 'x' : undef;
	cfs_write_file("user.cfg", $user_cfg);
    }, "enabling TFA for the user failed");
}

### OLD API

__PACKAGE__->register_method({
    name => 'verify_tfa',
    path => '',
    method => 'POST',
    permissions => { user => 'all' },
    protected => 1, # else we can't access shadow files
    allowtoken => 0, # we don't want tokens to access TFA information
    description => 'Finish a u2f challenge.',
    parameters => {
	additionalProperties => 0,
	properties => {
	    response => {
		type => 'string',
		description => 'The response to the current authentication challenge.',
	    },
	}
    },
    returns => {
	type => 'object',
	properties => {
	    ticket => { type => 'string' },
	    # cap
	}
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();
	my $authuser = $rpcenv->get_user();
	my ($username, undef, $realm) = PVE::AccessControl::verify_username($authuser);

	my ($tfa_type, $tfa_data) = PVE::AccessControl::user_get_tfa($username, $realm, 0);
	if (!defined($tfa_type)) {
	    raise('no u2f data available');
	}
	if ($tfa_type eq 'incompatible') {
	    raise('tfa entries incompatible with old login api');
	}

	eval {
	    if ($tfa_type eq 'u2f') {
		my $challenge = $rpcenv->get_u2f_challenge()
		   or raise('no active challenge');

		my $keyHandle = $tfa_data->{keyHandle};
		my $publicKey = $tfa_data->{publicKey};
		raise("incomplete u2f setup")
		    if !defined($keyHandle) || !defined($publicKey);

		my $u2f = PVE::API2::AccessControl::get_u2f_instance($rpcenv, $publicKey, $keyHandle);
		$u2f->set_challenge($challenge);

		my ($counter, $present) = $u2f->auth_verify($param->{response});
		# Do we want to do anything with these?
	    } else {
		# sanity check before handing off to the verification code:
		my $keys = $tfa_data->{keys} or die "missing tfa keys\n";
		my $config = $tfa_data->{config} or die "bad tfa entry\n";
		PVE::AccessControl::verify_one_time_pw($tfa_type, $authuser, $keys, $config, $param->{response});
	    }
	};
	if (my $err = $@) {
	    my $clientip = $rpcenv->get_client_ip() || '';
	    syslog('err', "authentication verification failure; rhost=$clientip user=$authuser msg=$err");
	    die PVE::Exception->new("authentication failure\n", code => 401);
	}

	return {
	    ticket => PVE::AccessControl::assemble_ticket($authuser),
	    cap => $rpcenv->compute_api_permission($authuser),
	}
    }});

### END OLD API

__PACKAGE__->register_method ({
    name => 'list_user_tfa',
    path => '{userid}',
    method => 'GET',
    permissions => {
	check => [ 'or',
	    ['userid-param', 'self'],
	    ['userid-group', ['User.Modify', 'Sys.Audit']],
	],
    },
    protected => 1, # else we can't access shadow files
    allowtoken => 0, # we don't want tokens to change the regular user's TFA settings
    description => 'List TFA configurations of users.',
    parameters => {
	additionalProperties => 0,
	properties => {
	    userid => get_standard_option('userid', {
		completion => \&PVE::AccessControl::complete_username,
	    }),
	}
    },
    returns => {
	description => "A list of the user's TFA entries.",
	type => 'array',
	items => $TYPED_TFA_ENTRY_SCHEMA,
    },
    code => sub {
	my ($param) = @_;
	my $tfa_cfg = cfs_read_file('priv/tfa.cfg');
	return $tfa_cfg->api_list_user_tfa($param->{userid});
    }});

__PACKAGE__->register_method ({
    name => 'get_tfa_entry',
    path => '{userid}/{id}',
    method => 'GET',
    permissions => {
	check => [ 'or',
	    ['userid-param', 'self'],
	    ['userid-group', ['User.Modify', 'Sys.Audit']],
	],
    },
    protected => 1, # else we can't access shadow files
    allowtoken => 0, # we don't want tokens to change the regular user's TFA settings
    description => 'Fetch a requested TFA entry if present.',
    parameters => {
	additionalProperties => 0,
	properties => {
	    userid => get_standard_option('userid', {
		completion => \&PVE::AccessControl::complete_username,
	    }),
	    id => $TFA_ID_SCHEMA,
	}
    },
    returns => $TYPED_TFA_ENTRY_SCHEMA,
    code => sub {
	my ($param) = @_;
	my $tfa_cfg = cfs_read_file('priv/tfa.cfg');
	my $id = $param->{id};
	my $entry = $tfa_cfg->api_get_tfa_entry($param->{userid}, $id);
	raise("No such tfa entry '$id'", code => HTTP::Status::HTTP_NOT_FOUND) if !$entry;
	return $entry;
    }});

__PACKAGE__->register_method ({
    name => 'delete_tfa',
    path => '{userid}/{id}',
    method => 'DELETE',
    permissions => {
	check => [ 'or',
	    ['userid-param', 'self'],
	    ['userid-group', ['User.Modify']],
	],
    },
    protected => 1, # else we can't access shadow files
    allowtoken => 0, # we don't want tokens to change the regular user's TFA settings
    description => 'Delete a TFA entry by ID.',
    parameters => {
	additionalProperties => 0,
	properties => {
	    userid => get_standard_option('userid', {
		completion => \&PVE::AccessControl::complete_username,
	    }),
	    id => $TFA_ID_SCHEMA,
	    password => $OPTIONAL_PASSWORD_SCHEMA,
	}
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	PVE::AccessControl::assert_new_tfa_config_available();
	
	my $rpcenv = PVE::RPCEnvironment::get();
	my $authuser = $rpcenv->get_user();
	my $userid =
	    root_permission_check($rpcenv, $authuser, $param->{userid}, $param->{password});

	my $has_entries_left = PVE::AccessControl::lock_tfa_config(sub {
	    my $tfa_cfg = cfs_read_file('priv/tfa.cfg');
	    my $has_entries_left = $tfa_cfg->api_delete_tfa($userid, $param->{id});
	    cfs_write_file('priv/tfa.cfg', $tfa_cfg);
	    return $has_entries_left;
	});
	if (!$has_entries_left) {
	    set_user_tfa_enabled($userid, undef, undef);
	}
    }});

__PACKAGE__->register_method ({
    name => 'list_tfa',
    path => '',
    method => 'GET',
    permissions => {
	description => "Returns all or just the logged-in user, depending on privileges.",
	user => 'all',
    },
    protected => 1, # else we can't access shadow files
    allowtoken => 0, # we don't want tokens to change the regular user's TFA settings
    description => 'List TFA configurations of users.',
    parameters => {
	additionalProperties => 0,
	properties => {}
    },
    returns => {
	description => "The list tuples of user and TFA entries.",
	type => 'array',
	items => {
	    type => 'object',
	    properties => {
		userid => {
		    type => 'string',
		    description => 'User this entry belongs to.',
		},
		entries => {
		    type => 'array',
		    items => $TYPED_TFA_ENTRY_SCHEMA,
		},
	    },
	},
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();
	my $authuser = $rpcenv->get_user();

	my $tfa_cfg = cfs_read_file('priv/tfa.cfg');
	my $entries = $tfa_cfg->api_list_tfa($authuser, 1);

	my $privs = [ 'User.Modify', 'Sys.Audit' ];
	if ($rpcenv->check_any($authuser, "/access/groups", $privs, 1)) {
	    # can modify all
	    return $entries;
	}

	my $groups = $rpcenv->filter_groups($authuser, $privs, 1);
	my $allowed_users = $rpcenv->group_member_join([keys %$groups]);
	return [
	    grep {
		my $userid = $_->{userid};
		$userid eq $authuser || $allowed_users->{$userid}
	    } $entries->@*
	];
    }});

__PACKAGE__->register_method ({
    name => 'add_tfa_entry',
    path => '{userid}',
    method => 'POST',
    permissions => {
	check => [ 'or',
	    ['userid-param', 'self'],
	    ['userid-group', ['User.Modify']],
	],
    },
    protected => 1, # else we can't access shadow files
    allowtoken => 0, # we don't want tokens to change the regular user's TFA settings
    description => 'Add a TFA entry for a user.',
    parameters => {
	additionalProperties => 0,
	properties => {
	    userid => get_standard_option('userid', {
		completion => \&PVE::AccessControl::complete_username,
	    }),
            type => $TFA_TYPE_SCHEMA,
	    description => {
		type => 'string',
		description => 'A description to distinguish multiple entries from one another',
		maxLength => 255,
		optional => 1,
	    },
	    totp => {
		type => 'string',
		description => "A totp URI.",
		optional => 1,
	    },
	    value => {
		type => 'string',
		description =>
		    'The current value for the provided totp URI, or a Webauthn/U2F'
		    .' challenge response',
		optional => 1,
	    },
	    challenge => {
		type => 'string',
		description => 'When responding to a u2f challenge: the original challenge string',
		optional => 1,
	    },
	    password => $OPTIONAL_PASSWORD_SCHEMA,
	},
    },
    returns => $TFA_UPDATE_INFO_SCHEMA,
    code => sub {
	my ($param) = @_;

	PVE::AccessControl::assert_new_tfa_config_available();

	my $rpcenv = PVE::RPCEnvironment::get();
	my $authuser = $rpcenv->get_user();
	my ($userid, $realm) =
	    root_permission_check($rpcenv, $authuser, $param->{userid}, $param->{password});

	my $type = delete $param->{type};
	my $value = delete $param->{value};
	if ($type eq 'yubico') {
	    $value = validate_yubico_otp($userid, $realm, $value);
	}

	return PVE::AccessControl::lock_tfa_config(sub {
	    my $tfa_cfg = cfs_read_file('priv/tfa.cfg');

	    set_user_tfa_enabled($userid, $realm, $tfa_cfg);

	    PVE::AccessControl::configure_u2f_and_wa($tfa_cfg);

	    my $response = $tfa_cfg->api_add_tfa_entry(
		$userid,
		$param->{description},
		$param->{totp},
		$value,
		$param->{challenge},
		$type,
	    );

	    cfs_write_file('priv/tfa.cfg', $tfa_cfg);

	    return $response;
	});
    }});

sub validate_yubico_otp : prototype($$) {
    my ($userid, $realm, $value) = @_;

    my $domain_cfg = cfs_read_file('domains.cfg');
    my $realm_cfg = $domain_cfg->{ids}->{$realm};
    die "auth domain '$realm' does not exist\n" if !$realm_cfg;

    my $realm_tfa = $realm_cfg->{tfa};
    die "no yubico otp configuration available for realm $realm\n"
	if !$realm_tfa;

    $realm_tfa = PVE::Auth::Plugin::parse_tfa_config($realm_tfa);
    die "realm is not setup for Yubico OTP\n"
	if !$realm_tfa || $realm_tfa->{type} ne 'yubico';

    my $public_key = substr($value, 0, 12);

    PVE::AccessControl::authenticate_yubico_do($value, $public_key, $realm_tfa);

    return $public_key;
}

__PACKAGE__->register_method ({
    name => 'update_tfa_entry',
    path => '{userid}/{id}',
    method => 'PUT',
    permissions => {
	check => [ 'or',
	    ['userid-param', 'self'],
	    ['userid-group', ['User.Modify']],
	],
    },
    protected => 1, # else we can't access shadow files
    allowtoken => 0, # we don't want tokens to change the regular user's TFA settings
    description => 'Add a TFA entry for a user.',
    parameters => {
	additionalProperties => 0,
	properties => {
	    userid => get_standard_option('userid', {
		completion => \&PVE::AccessControl::complete_username,
	    }),
	    id => $TFA_ID_SCHEMA,
	    description => {
		type => 'string',
		description => 'A description to distinguish multiple entries from one another',
		maxLength => 255,
		optional => 1,
	    },
	    enable => {
		type => 'boolean',
		description => 'Whether the entry should be enabled for login.',
		optional => 1,
	    },
	    password => $OPTIONAL_PASSWORD_SCHEMA,
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	PVE::AccessControl::assert_new_tfa_config_available();

	my $rpcenv = PVE::RPCEnvironment::get();
	my $authuser = $rpcenv->get_user();
	my $userid =
	    root_permission_check($rpcenv, $authuser, $param->{userid}, $param->{password});

	PVE::AccessControl::lock_tfa_config(sub {
	    my $tfa_cfg = cfs_read_file('priv/tfa.cfg');

	    $tfa_cfg->api_update_tfa_entry(
		$userid,
		$param->{id},
		$param->{description},
		$param->{enable},
	    );

	    cfs_write_file('priv/tfa.cfg', $tfa_cfg);
	});
    }});

1;
