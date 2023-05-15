package PVE::pvecfg;

use strict;
use warnings;

sub package {
    return 'pve-manager';
}

sub version {
    return '7.4-3';
}

sub release {
    return '7.4';
}

sub repoid {
    return '9002ab8a';
}

sub version_text {
    return '7.4-3/9002ab8a';
}

# this is returned by the API
sub version_info {
    return {
	'version' => '7.4-3',
	'release' => '7.4',
	'repoid' => '9002ab8a',
    }
}

1;
