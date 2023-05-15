package PVE::ACME::StandAlone;

use strict;
use warnings;

use HTTP::Daemon;
use HTTP::Response;

use base qw(PVE::ACME::Challenge);

sub supported_challenge_types {
    return ['http-01'];
}

sub type {
    return 'standalone';
}

sub properties {
    return {};
}

sub options {
    return {
	nodes => { optional => 1 },
	disable => { optional => 1 },
    };
}

sub setup {
    my ($self, $acme, $auth, $data) = @_;

    print "Setting up webserver\n";

    my $challenge = $self->extract_challenge($auth->{challenges});
    my $key_auth = $acme->key_authorization($challenge->{token});

    my %sockopts = (
	LocalPort => 80,
	ReuseAddr => 1,
	);
    my $server = HTTP::Daemon->new( LocalHost => '::', V6Only => 0, %sockopts) //
	    HTTP::Daemon->new( LocalHost => '0.0.0.0', %sockopts)
	    or die "Failed to initialize HTTP daemon\n";

    my $pid = fork() // die "Failed to fork HTTP daemon - $!\n";
    if ($pid) {
	$data->{server} = $server;
	$data->{pid} = $pid;
	$data->{url} = $challenge->{url};
    } else {
	while (my $c = $server->accept()) {
	    while (my $r = $c->get_request()) {
		if ($r->method() eq 'GET' and
		    $r->uri->path eq "/.well-known/acme-challenge/$challenge->{token}") {
		    my $resp = HTTP::Response->new(200, 'OK', undef, $key_auth);
		    $resp->request($r);
		    $c->send_response($resp);
		} else {
		    $c->send_error(404, 'Not found.')
		}
	    }
	    $c->close();
	    $c = undef;
	}
    }
}

sub teardown {
    my ($self, $acme, $auth, $data) = @_;

    eval { $data->{server}->close() };
    kill('KILL', $data->{pid});
    waitpid($data->{pid}, 0);
}

1;
