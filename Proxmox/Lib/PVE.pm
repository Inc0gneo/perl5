package Proxmox::Lib::PVE;

=head1 NAME

Proxmox::Lib::PVE - base module for PVE rust bindings

=head1 SYNOPSIS

    package PVE::RS::SomeBindings;

    use base 'Proxmox::Lib::PVE';

    BEGIN { __PACKAGE__->bootstrap(); }

    1;

=head1 DESCRIPTION

This is the base module of all PVE bindings.
Its job is to ensure the 'libpve_rs.so' library is loaded and provide a 'bootstrap' class
method to load the actual code.

=cut

use DynaLoader;

sub library {
    return 'pve_rs';
}

# Keep on a single line, modified by testsuite!
sub libdirs { return (map "-L$_/auto", @INC); }

sub load : prototype($) {
    my ($pkg) = @_;

    my $mod_name = $pkg->library();

    my @dirs = $pkg->libdirs();
    my $mod_file = DynaLoader::dl_findfile(@dirs, $mod_name);
    die "failed to locate shared library for $mod_name (lib${mod_name}.so)\n" if !$mod_file;

    my $lib = DynaLoader::dl_load_file($mod_file)
	or die "failed to load library '$mod_file'\n";

    my $data = ($::{'proxmox-rs-library'} //= {});
    $data->{$mod_name} = $lib;
    $data->{-current} //= $lib;
    $data->{-package} //= $pkg;
}

sub bootstrap {
    my ($pkg) = @_;

    my $mod_name = $pkg->library();

    my $bootstrap_name = 'boot_' . ($pkg =~ s/::/__/gr);

    my $lib = $::{'proxmox-rs-library'}
	or die "rust library not available for '{PRODUCT}'\n";
    $lib = $lib->{$mod_name};

    my $sym  = DynaLoader::dl_find_symbol($lib, $bootstrap_name);
    die "failed to locate '$bootstrap_name'\n" if !defined $sym;
    my $boot = DynaLoader::dl_install_xsub($bootstrap_name, $sym, "src/FIXME.rs");
    $boot->();
}

BEGIN {
    __PACKAGE__->load();
    __PACKAGE__->bootstrap();
    init();
}

1;
