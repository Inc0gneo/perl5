package PVE::U2F;

use 5.024000;
use strict;
use warnings;

require Exporter;

our @ISA = qw(Exporter);

# Items to export into callers namespace by default. Note: do not export
# names by default without a very good reason. Use EXPORT_OK instead.
# Do not simply export all your public functions/methods/constants.

# This allows declaration	use PVE::U2F::XS ':all';
# If you do not need this, moving things directly into @EXPORT or @EXPORT_OK
# will save memory.
our %EXPORT_TAGS = ( 'all' => [] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT = ();
our $VERSION = '1.0';

require XSLoader;
XSLoader::load('PVE::U2F', $VERSION);

#### Context creation

my $global_init = 0;
sub new($) {
    my ($class) = @_;
    if (!$global_init) {
	$global_init = 1;
	do_global_init();
    }
    if (my $lib = new_impl()) {
	return bless { ctx => $lib }, $class;
    }
    return undef;
}

sub DESTROY {
	my ($self) = @_;
	done_impl($self->{ctx});
}

#### Error handling

my @errcodes = (
qw(memory json base64 crypto origin challenge signature format)
);
sub checkrc($) {
    my ($rc) = @_;
    return if $rc == 0;
    die "u2fs: $errcodes[-$rc-1] error\n" if $rc < 0 && $rc >= -8;
    die "u2fs: unknown error\n";
}

#### Context initialization

sub origin($) { return $_[0]->{origin}; }
sub set_origin($$) {
    my ($self, $origin) = @_;
    checkrc(set_origin_impl($self->{ctx}, $origin));
    return $self->{origin} = $origin;
}

sub appid($) { return $_[0]->{appid}; }
sub set_appid($$) {
    my ($self, $appid) = @_;
    checkrc(set_appid_impl($self->{ctx}, $appid));
    return $self->{appid} = $appid;
}

sub challenge($) { return $_[0]->{challenge}; }
sub set_challenge($$) {
    my ($self, $challenge) = @_;
    checkrc(set_challenge_impl($self->{ctx}, $challenge));
    return $self->{challenge} = $challenge;
}

sub keyHandle($) { return $_[0]->{keyHandle}; }
sub set_keyHandle($$) {
    my ($self, $keyHandle) = @_;
    checkrc(set_keyHandle_impl($self->{ctx}, $keyHandle));
    return $self->{keyHandle} = $keyHandle;
}

sub publicKey($) { return $_[0]->{publicKey}; }
sub set_publicKey($$) {
    my ($self, $publicKey) = @_;
    checkrc(set_publicKey_impl($self->{ctx}, $publicKey));
    return $self->{publicKey} = $publicKey;
}

#### Registration

sub registration_challenge($) {
    my ($self) = @_;
    checkrc(registration_challenge_impl($self->{ctx}, my $challenge));
    return $challenge;
}

sub registration_verify($$) {
    my ($self, $response) = @_;
    checkrc(registration_verify_impl($self->{ctx}, $response, my $kh, my $pk));
    return ($kh, $pk);
}

#### Authentication

sub auth_challenge($) {
    my ($self) = @_;
    checkrc(auth_challenge_impl($self->{ctx}, my $challenge));
    return $challenge;
}

sub auth_verify($$) {
    my ($self, $response) = @_;
    checkrc(auth_verify_impl($self->{ctx}, $response,
	my $verified,
	my $counter,
	my $presence));
    checkrc($verified);
    return wantarray ? ($counter, $presence) : 1;
}

1;
__END__

=head1 NAME

PVE::U2F - Perl bindings for libu2f-server

=head1 SYNOPSIS

  use PVE::U2F;

=head1 DESCRIPTION

Perl bindings for libu2f-server

=head2 EXPORT

None by default.

=head1 SEE ALSO

TODO

=head1 AUTHOR

Proxmox Server Solutions GmbH <support@proxmox.com>

=cut
