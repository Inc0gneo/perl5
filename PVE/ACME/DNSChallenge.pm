package PVE::ACME::DNSChallenge;

use strict;
use warnings;

use Digest::SHA qw(sha256);
use JSON;

use PVE::Tools;

use PVE::ACME;

use base qw(PVE::ACME::Challenge);

my $ACME_PATH = '/usr/share/proxmox-acme/proxmox-acme';

sub supported_challenge_types {
    return ["dns-01"];
}

sub type {
    return 'dns';
}

my $DNS_API_CHALLENGE_SCHEMA_FN = '/usr/share/proxmox-acme/dns-challenge-schema.json';

my $plugin_cache;
sub get_supported_plugins {
    if (!$plugin_cache) {
	$plugin_cache = -e $DNS_API_CHALLENGE_SCHEMA_FN # we allow this to be optional as not all users require
	    ? from_json(PVE::Tools::file_get_contents($DNS_API_CHALLENGE_SCHEMA_FN))
	    : {};
    }
    return $plugin_cache;
}

sub properties {
    my $plugins = get_supported_plugins();
    return {
	api => {
	    description => "API plugin name",
	    type => 'string',
	    enum => [sort keys %$plugins],
	},
	data => {
	    type => 'string',
	    description => 'DNS plugin data. (base64 encoded)',
	},
	'validation-delay' => {
	    type => 'integer',
	    description => 'Extra delay in seconds to wait before requesting validation.'
	        .' Allows to cope with a long TTL of DNS records.',
	    # low default, but our bet is that the acme-challenge domain isn't
	    # cached at all, so it hopefully shouldn't run into TTL issues
	    default => 30,
	    optional => 1,
	    minimum => 0,
	    maximum => 2 * 24 * 60 * 60,
	}
    };
}

sub options {
    return {
	api => {},
	data => { optional => 1 },
	nodes => { optional => 1 },
	disable => { optional => 1 },
	'validation-delay' => { optional => 1 },
    };
}

my $proxmox_acme_command = sub {
    my ($self, $acme, $auth, $data, $action) = @_;

    die "No plugin data for DNSChallenge\n" if !defined($data->{plugin});

    my $alias = $data->{alias};
    my $domain = $auth->{identifier}->{value};

    my $challenge = $self->extract_challenge($auth->{challenges});
    my $key_auth = $acme->key_authorization($challenge->{token});

    my $txtvalue = PVE::ACME::encode(sha256($key_auth));
    my $dnsplugin = $data->{plugin}->{api};
    my $plugin_conf_string = $data->{plugin}->{data};

    # for security reasons, we execute the command as nobody
    # we can't verify that the code of the DNSPlugins are harmless.
    my $cmd = ["setpriv", "--reuid", "nobody", "--regid", "nogroup", "--clear-groups", "--reset-env", "--"];

    # The order of the parameters passed to proxmox-acme is important
    # proxmox-acme <setup|teardown> $plugin <$domain|$alias> $txtvalue [$plugin_conf_string]
    push @$cmd, "/bin/bash", $ACME_PATH, $action, $dnsplugin;
    if ($alias) {
	push @$cmd, $alias;
    } else {
	push @$cmd, $domain;
    }
    my $input = "$txtvalue\n";
    $input .= "$plugin_conf_string\n" if $plugin_conf_string;

    PVE::Tools::run_command($cmd, input => $input);

    $data->{url} = $challenge->{url};

    return $domain;
};

sub setup {
    my ($self, $acme, $auth, $data) = @_;

    my $domain = $proxmox_acme_command->($self, $acme, $auth, $data, 'setup');
    print "Add TXT record: _acme-challenge.$domain\n";

    my $delay = $data->{plugin}->{'validation-delay'} // 30;
    if ($delay > 0) {
	print "Sleeping $delay seconds to wait for TXT record propagation\n";
	sleep($delay); # don't care for EINTR
    }
}

sub teardown {
    my ($self, $acme, $auth, $data) = @_;

    my $domain = $proxmox_acme_command->($self, $acme, $auth, $data, 'teardown');
    print "Remove TXT record: _acme-challenge.$domain\n";
}

1;
