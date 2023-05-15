package PVE::ACME::Challenge;

use strict;
use warnings;

use PVE::JSONSchema qw(get_standard_option);

use base qw(PVE::SectionConfig);

my $defaultData = {
    additionalProperties => 0,
    propertyList => {
	id => {
	    description => "ACME Plugin ID name",
	    type => 'string',
	    format => 'pve-configid',
	},
	type => {
	    description => "ACME challenge type.",
	    type => 'string',
	},
	disable => {
	    description => "Flag to disable the config.",
	    type => 'boolean',
	    optional => 1,
	},
	nodes => get_standard_option('pve-node-list', { optional => 1 }),
    },
};

sub private {
    return $defaultData;
}

sub parse_config {
    my ($class, $filename, $raw) = @_;

    my $cfg = $class->SUPER::parse_config($filename, $raw);
    my $ids = $cfg->{ids};

    # make sure we have a standalone plugin definition as fallback!
    if (!$ids->{standalone} || $ids->{standalone}->{type} ne 'standalone') {
	$ids->{standalone} = {
	    type => 'standalone',
	};
    }

    return $cfg;
}

sub encode_value {
    my ($self, $type, $key, $value) = @_;

    if ($key eq 'data') {
	$value = MIME::Base64::encode_base64url($value);
    }

    return $value;
};

sub decode_value {
    my ($self, $type, $key, $value) = @_;

    if ($key eq 'data') {
	$value = MIME::Base64::decode_base64url($value);
    }

    return $value;
};

sub supported_challenge_types {
    return [];
}

sub extract_challenge {
    my ($self, $challenges) = @_;

    die "no challenges defined\n" if !$challenges;

    my $supported_types = $self->supported_challenge_types();

    # preference returned by plugin!
    foreach my $supported_type (@$supported_types) {
	foreach my $challenge (@$challenges) {
	    next if $challenge->{type} ne $supported_type;

	    return $challenge;
	}
    }

    die "plugin does not support any of the requested challenge types\n";
}

# acme => PVE::ACME instance
# auth => authorization object returned by ACME server
# $data => {
#   plugin => plugin config data
#   alias => optional domain alias
# }
# needs to set $data->{url} to URL of the challenge which has been set up
# can set other $data keys needed by teardown sub
sub setup {
    my ($self, $acme, $auth, $data) = @_;

    die "implement me\n";
}

# see setup
sub teardown {
    my ($self, $acme, $auth, $data) = @_;

    die "implement me\n";
}

1;
