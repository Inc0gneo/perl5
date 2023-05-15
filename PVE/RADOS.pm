package PVE::RADOS;

use 5.014002;

use strict;
use warnings;

use Carp;
use JSON;
use Socket;

use PVE::Tools;
use PVE::INotify;
use PVE::RPCEnvironment;

require Exporter;

my $rados_default_timeout = 5;
my $ceph_default_conf = '/etc/pve/ceph.conf';
my $ceph_default_user = 'admin';


our $VERSION = '1.0';

require XSLoader;
XSLoader::load('PVE::RADOS', $VERSION);

my $writedata = sub {
    my ($fh, $cmd, $data) = @_;

    local $SIG{PIPE} = 'IGNORE';

    my $bin = pack "a L/a*", $cmd, $data || '';
    my $res = syswrite $fh, $bin;

    die "write data failed - $!\n" if !defined($res);
};

my $readdata = sub {
    my ($fh, $allow_eof) = @_;

    my $head = '';

    local $SIG{PIPE} = 'IGNORE';

    while (length($head) < 5) {
	last if !sysread $fh, $head, 5 - length($head), length($head);
    }
    return undef if $allow_eof && length($head) == 0;

    die "partial read\n" if length($head) < 5;

    my ($cmd, $len) = unpack "a L", $head;

    my $data = '';
    while (length($data) < $len) {
	last if !sysread $fh, $data, $len - length($data), length($data);
    }
    die "partial data read\n" if length($data) < $len;

    return wantarray ? ($cmd, $data) : $data;
};

my $kill_worker = sub {
    my ($self) = @_;

    return if !$self->{cpid};
    return if  $self->{__already_killed};

    $self->{__already_killed} = 1;

    close($self->{child}) if defined($self->{child});

    # only kill if we created the process
    return if $self->{pid} != $$;

    kill(9, $self->{cpid});
    waitpid($self->{cpid}, 0);
};

my $sendcmd = sub {
    my ($self, $cmd, $data, $expect_tag) = @_;

    $expect_tag = '>' if !$expect_tag;

    die "detected forked connection\n" if $self->{pid} != $$;

    my ($restag, $raw);
    my $code = sub {
	&$writedata($self->{child}, $cmd, $data) if $expect_tag ne 'S';
	($restag, $raw) = &$readdata($self->{child});
    };
    eval { PVE::Tools::run_with_timeout($self->{timeout}, $code); };
    if (my $err = $@) {
	&$kill_worker($self);
	die $err;
    }
    if ($restag eq 'E') {
	die $raw if $raw;
	die "unknown error\n";
    }

    die "got unexpected result\n" if $restag ne $expect_tag;

    return $raw;
};

sub new {
    my ($class, %params) = @_;

    my $rpcenv = PVE::RPCEnvironment::get();

    socketpair(my $child, my $parent, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
	||  die "socketpair: $!\n";

    my $cpid = fork();

    die "unable to fork - $!\n" if !defined($cpid);

    my $self = bless {}, $class;

    my $timeout = delete $params{timeout} || $rados_default_timeout;

    $self->{timeout} = $timeout;
    $self->{pid} = $$;

    if ($cpid) { # parent
	close $parent;

	$self->{cpid} = $cpid;
	$self->{child} = $child;

	&$sendcmd($self, undef, undef, 'S'); # wait for sync

    } else { # child
	$0 = 'pverados';

	PVE::INotify::inotify_close();

	if (my $atfork = $rpcenv->{atfork}) {
	    &$atfork();
	}

	# fixme: timeout?

	close $child;

	my $conn;
	eval {
	    my $ceph_user = delete $params{userid} || $ceph_default_user;
	    $conn = pve_rados_create($ceph_user) ||
		die "unable to create RADOS object\n";

	    if (defined($params{ceph_conf}) && (!-e $params{ceph_conf})) {
		die "Supplied ceph config doesn't exist, $params{ceph_conf}\n";
	    }

	    my $ceph_conf = delete $params{ceph_conf} || $ceph_default_conf;

	    if (-e $ceph_conf) {
		pve_rados_conf_read_file($conn, $ceph_conf);
	    }

	    pve_rados_conf_set($conn, 'client_mount_timeout', $timeout);

	    foreach my $k (keys %params) {
		pve_rados_conf_set($conn, $k, $params{$k});
	    }

	    pve_rados_connect($conn);
	};
	if (my $err = $@) {
	    &$writedata($parent, 'E', $err);
	    die $err;
	}
	&$writedata($parent, 'S');

	$self->{conn} = $conn;

	for (;;) {
	    my ($cmd, $data) = &$readdata($parent, 1);

	    last if !$cmd || $cmd eq 'Q';

	    my $res;
	    eval {
		if ($cmd eq 'M') { # rados monitor commands
		    $res = encode_json(pve_rados_mon_command($self->{conn}, [ $data ]));
		} elsif ($cmd eq 'C') { # class methods
		    my $aref = decode_json($data);
		    my $method = shift @$aref;
		    $res = encode_json($self->$method(@$aref));
		} else {
		    die "invalid command\n";
		}
	    };
	    if (my $err = $@) {
		&$writedata($parent, 'E', $err);
		die $err;
	    }
	    &$writedata($parent, '>', $res);
	}

	exit(0);
    }

    return $self;
}

sub timeout {
    my ($self, $new_timeout) = @_;

    $self->{timeout} = $new_timeout if $new_timeout;

    return $self->{timeout};
}

sub DESTROY {
    my ($self) = @_;

    if ($self->{cpid}) {
	#print "$$: DESTROY WAIT0\n";
	&$kill_worker($self);
	#print "$$: DESTROY WAIT\n";
    } else {
	#print "$$: DESTROY SHUTDOWN\n";
	pve_rados_shutdown($self->{conn}) if $self->{conn};
    }
}

sub cluster_stat {
    my ($self, @args) = @_;

    if ($self->{cpid}) {
	my $data = encode_json(['cluster_stat', @args]);
	my $raw = &$sendcmd($self, 'C', $data);
	return decode_json($raw);
    } else {
	return pve_rados_cluster_stat($self->{conn});
    }
}

# example1: { prefix => 'get_command_descriptions'})
# example2: { prefix => 'mon dump', format => 'json' }
sub mon_cmd {
    my ($self, $cmd, $no_result_catch) = @_;

    $cmd->{format} = 'json' if !$cmd->{format};

    my $json = encode_json($cmd);

    my $ret = $sendcmd->($self, 'M', $json);
    die "error with '$cmd->{prefix}': $@" if $@;

    my $raw = decode_json($ret);

    die "error with '$cmd->{prefix}': mon_cmd failed - $raw->{status_message}\n"
	if !$no_result_catch && $raw->{return_code} < 0;

    my $data = '';
    if ($cmd->{format} && $cmd->{format} eq 'json') {
	$data = length($raw->{data}) ? decode_json($raw->{data}) : undef;
    } else {
	$data = $raw->{data};
    }
    return {
	return_code => $raw->{return_code},
	status_message => $raw->{status_message},
	data => $data,
    };
}

# for backward compatibillity or if one just doesn't care about actual RADOS error details
sub mon_command {
    my ($self, $cmd) = @_;

    my $res = mon_cmd($self, $cmd);

    return $res->{data};
}

1;
__END__

=head1 NAME

PVE::RADOS - Perl bindings for librados

=head1 SYNOPSIS

  use PVE::RADOS;

  my $rados = PVE::RADOS->new();
  my $stat = $rados->cluster_stat();
  my $res = $rados->mon_command({ prefix => 'mon dump', format => 'json' });

=head1 DESCRIPTION

Perl bindings for librados.

=head2 EXPORT

None by default.

=head1 AUTHOR

Dietmar Maurer, E<lt>dietmar@proxmox.com<gt>
Thomas Lamprecht E<lt>t.lamprecht@proxmox.com<gt>
Wolfgang Bumiller E<lt>w.bumiller@proxmox.com<gt>

=cut
