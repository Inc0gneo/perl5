package HTTP::Daemon; # git description: v6.11-4-g1c1c9bc

# ABSTRACT: A simple http server class

use strict;
use warnings;

our $VERSION = '6.12';

use Socket ();
use IO::Socket::IP;
our @ISA = qw(IO::Socket::IP);

our $PROTO = "HTTP/1.1";

our $DEBUG;

sub new {
    my ($class, %args) = @_;
    $args{Listen} ||= 5;
    $args{Proto}  ||= 'tcp';

    # Handle undefined or empty local address the same way as
    # IO::Socket::INET -- use unspecified address
    for my $key (qw(LocalAddr LocalHost)) {
        if (exists $args{$key} && (!defined $args{$key} || $args{$key} eq '')) {
            delete $args{$key};
        }
    }
    return $class->SUPER::new(%args);
}

sub accept {
    my $self = shift;
    my $pkg  = shift || "HTTP::Daemon::ClientConn";
    my ($sock, $peer) = $self->SUPER::accept($pkg);
    if ($sock) {
        ${*$sock}{'httpd_daemon'} = $self;
        return wantarray ? ($sock, $peer) : $sock;
    }
    else {
        return;
    }
}

sub url {
    my $self = shift;

    my $host = $self->sockhost;
    $host =~ s/%/%25/g;
    $host = "127.0.0.1" if $host eq "0.0.0.0";
    $host = "::1"       if $host eq "::";
    $host = "[$host]"   if $self->sockdomain == Socket::AF_INET6;

    my $url = $self->_default_scheme . "://" . $host;
    my $port = $self->sockport;
    $url .= ":$port" if $port != $self->_default_port;
    $url .= "/";
    $url;
}

sub _default_port {
    80;
}

sub _default_scheme {
    "http";
}

sub product_tokens {
    "libwww-perl-daemon/$HTTP::Daemon::VERSION";
}

package    # hide from PAUSE
    HTTP::Daemon::ClientConn;

use strict;
use warnings;

use IO::Socket::IP ();
our @ISA = qw(IO::Socket::IP);
our $DEBUG;
*DEBUG = \$HTTP::Daemon::DEBUG;

use HTTP::Request  ();
use HTTP::Response ();
use HTTP::Status;
use HTTP::Date qw(time2str);
use LWP::MediaTypes qw(guess_media_type);
use Carp ();

# "\r\n" is not portable
my $CRLF     = "\015\012";
my $HTTP_1_0 = _http_version("HTTP/1.0");
my $HTTP_1_1 = _http_version("HTTP/1.1");


sub get_request {
    my ($self, $only_headers) = @_;
    if (${*$self}{'httpd_nomore'}) {
        $self->reason("No more requests from this connection");
        return;
    }

    $self->reason("");
    my $buf = ${*$self}{'httpd_rbuf'};
    $buf = "" unless defined $buf;

    my $timeout = ${*$self}{'io_socket_timeout'};
    my $fdset   = "";
    vec($fdset, $self->fileno, 1) = 1;
    local ($_);

READ_HEADER:
    while (1) {

        # loop until we have the whole header in $buf
        $buf =~ s/^(?:\015?\012)+//;    # ignore leading blank lines
        if ($buf =~ /\012/) {           # potential, has at least one line
            if ($buf =~ /^\w+[^\012]+HTTP\/\d+\.\d+\015?\012/) {
                if ($buf =~ /\015?\012\015?\012/) {
                    last READ_HEADER;    # we have it
                }
                elsif (length($buf) > 16 * 1024) {
                    $self->send_error(413);    # REQUEST_ENTITY_TOO_LARGE
                    $self->reason("Very long header");
                    return;
                }
            }
            else {
                last READ_HEADER;              # HTTP/0.9 client
            }
        }
        elsif (length($buf) > 16 * 1024) {
            $self->send_error(414);            # REQUEST_URI_TOO_LARGE
            $self->reason("Very long first line");
            return;
        }
        print STDERR "Need more data for complete header\n" if $DEBUG;
        return unless $self->_need_more($buf, $timeout, $fdset);
    }
    if ($buf !~ s/^(\S+)[ \t]+(\S+)(?:[ \t]+(HTTP\/\d+\.\d+))?[^\012]*\012//) {
        ${*$self}{'httpd_client_proto'} = _http_version("HTTP/1.0");
        $self->send_error(400);                # BAD_REQUEST
        $self->reason("Bad request line: $buf");
        return;
    }
    my $method = $1;
    my $uri    = $2;
    my $proto  = $3 || "HTTP/0.9";
    $uri = "http://$uri" if $method eq "CONNECT";
    $uri = $HTTP::URI_CLASS->new($uri, $self->daemon->url);
    my $r = HTTP::Request->new($method, $uri);
    $r->protocol($proto);
    ${*$self}{'httpd_client_proto'} = $proto = _http_version($proto);
    ${*$self}{'httpd_head'} = ($method eq "HEAD");

    if ($proto >= $HTTP_1_0) {

        # we expect to find some headers
        my ($key, $val);
    HEADER:
        while ($buf =~ s/^([^\012]*)\012//) {
            $_ = $1;
            s/\015$//;
            if (/^([^:\s]+)\s*:\s*(.*)/) {
                $r->push_header($key, $val) if $key;
                ($key, $val) = ($1, $2);
            }
            elsif (/^\s+(.*)/) {
                $val .= " $1";
            }
            else {
                last HEADER;
            }
        }
        $r->push_header($key, $val) if $key;
    }

    my $conn = $r->header('Connection');
    if ($proto >= $HTTP_1_1) {
        ${*$self}{'httpd_nomore'}++ if $conn && lc($conn) =~ /\bclose\b/;
    }
    else {
        ${*$self}{'httpd_nomore'}++
            unless $conn && lc($conn) =~ /\bkeep-alive\b/;
    }

    if ($only_headers) {
        ${*$self}{'httpd_rbuf'} = $buf;
        return $r;
    }

    # Find out how much content to read
    my $tr_enc  = $r->header('Transfer-Encoding');
    my $ct_type = $r->header('Content-Type');
    my $ct_len  = $r->header('Content-Length');

    # Act on the Expect header, if it's there
    for my $e ($r->header('Expect')) {
        if (lc($e) eq '100-continue') {
            $self->send_status_line(100);
            $self->send_crlf;
        }
        else {
            $self->send_error(417);
            $self->reason("Unsupported Expect header value");
            return;
        }
    }

    if ($tr_enc && lc($tr_enc) eq 'chunked') {

        # Handle chunked transfer encoding
        my $body = "";
    CHUNK:
        while (1) {
            print STDERR "Chunked\n" if $DEBUG;
            if ($buf =~ s/^([^\012]*)\012//) {
                my $chunk_head = $1;
                unless ($chunk_head =~ /^([0-9A-Fa-f]+)/) {
                    $self->send_error(400);
                    $self->reason("Bad chunk header $chunk_head");
                    return;
                }
                my $size = hex($1);
                last CHUNK if $size == 0;

                my $missing = $size - length($buf) + 2;    # 2=CRLF at chunk end
                     # must read until we have a complete chunk
                while ($missing > 0) {
                    print STDERR "Need $missing more bytes\n" if $DEBUG;
                    my $n = $self->_need_more($buf, $timeout, $fdset);
                    return unless $n;
                    $missing -= $n;
                }
                $body .= substr($buf, 0, $size);
                substr($buf, 0, $size + 2) = '';

            }
            else {
                # need more data in order to have a complete chunk header
                return unless $self->_need_more($buf, $timeout, $fdset);
            }
        }
        $r->content($body);

        # pretend it was a normal entity body
        $r->remove_header('Transfer-Encoding');
        $r->header('Content-Length', length($body));

        my ($key, $val);
    FOOTER:
        while (1) {
            if ($buf !~ /\012/) {

                # need at least one line to look at
                return unless $self->_need_more($buf, $timeout, $fdset);
            }
            else {
                $buf =~ s/^([^\012]*)\012//;
                $_ = $1;
                s/\015$//;
                if (/^([\w\-]+)\s*:\s*(.*)/) {
                    $r->push_header($key, $val) if $key;
                    ($key, $val) = ($1, $2);
                }
                elsif (/^\s+(.*)/) {
                    $val .= " $1";
                }
                elsif (!length) {
                    last FOOTER;
                }
                else {
                    $self->reason("Bad footer syntax");
                    return;
                }
            }
        }
        $r->push_header($key, $val) if $key;

    }
    elsif ($tr_enc) {
        $self->send_error(501);    # Unknown transfer encoding
        $self->reason("Unknown transfer encoding '$tr_enc'");
        return;

    }
    elsif ($ct_len) {

        # After a security issue, we ensure we comply to
        # RFC-7230 -- HTTP/1.1 Message Syntax and Routing
        # section 3.3.2 -- Content-Length
        # section 3.3.3 -- Message Body Length

        # split and clean up Content-Length ', ' separated string
        my @vals = map {my $str = $_; $str =~ s/^\s+//; $str =~ s/\s+$//; $str }
            split ',', $ct_len;
        # check that they are all numbers (RFC: Content-Length = 1*DIGIT)
        my @nums = grep { /^[0-9]+$/} @vals;
        unless (@vals == @nums) {
            my $reason = "Content-Length value must be an unsigned integer";
            $self->send_error(400, $reason);
            $self->reason($reason);
            return;
        }
        # check they are all the same
        my $ct_len = shift @nums;
        foreach (@nums) {
            next if $_ == $ct_len;
            my $reason = "Content-Length values are not the same";
            $self->send_error(400, $reason);
            $self->reason($reason);
            return;
        }
        # ensure we have now a fixed header, with only 1 value
        $r->header('Content-Length' => $ct_len);

        # Plain body specified by "Content-Length"
        my $missing = $ct_len - length($buf);
        while ($missing > 0) {
            print "Need $missing more bytes of content\n" if $DEBUG;
            my $n = $self->_need_more($buf, $timeout, $fdset);
            return unless $n;
            $missing -= $n;
        }
        if (length($buf) > $ct_len) {
            $r->content(substr($buf, 0, $ct_len));
            substr($buf, 0, $ct_len) = '';
        }
        else {
            $r->content($buf);
            $buf = '';
        }
    }
    elsif ($ct_type && $ct_type =~ m/^multipart\/\w+\s*;.*boundary\s*=\s*("?)(\w+)\1/i) {

        # Handle multipart content type
        my $boundary = "$CRLF--$2--";
        my $index;
        while (1) {
            $index = index($buf, $boundary);
            last if $index >= 0;

            # end marker not yet found
            return unless $self->_need_more($buf, $timeout, $fdset);
        }
        $index += length($boundary);
        $r->content(substr($buf, 0, $index));
        substr($buf, 0, $index) = '';

    }
    ${*$self}{'httpd_rbuf'} = $buf;

    $r;
}

sub _need_more {
    my $self = shift;

    #my($buf,$timeout,$fdset) = @_;
    if ($_[1]) {
        my ($timeout, $fdset) = @_[1, 2];
        print STDERR "select(,,,$timeout)\n" if $DEBUG;
        my $n = select($fdset, undef, undef, $timeout);
        unless ($n) {
            $self->reason(defined($n) ? "Timeout" : "select: $!");
            return;
        }
    }
    print STDERR "sysread()\n" if $DEBUG;
    my $n = sysread($self, $_[0], 2048, length($_[0]));
    $self->reason(defined($n) ? "Client closed" : "sysread: $!") unless $n;
    $n;
}

sub read_buffer {
    my $self = shift;
    my $old  = ${*$self}{'httpd_rbuf'};
    if (@_) {
        ${*$self}{'httpd_rbuf'} = shift;
    }
    $old;
}

sub reason {
    my $self = shift;
    my $old  = ${*$self}{'httpd_reason'};
    if (@_) {
        ${*$self}{'httpd_reason'} = shift;
    }
    $old;
}

sub proto_ge {
    my $self = shift;
    ${*$self}{'httpd_client_proto'} >= _http_version(shift);
}

sub _http_version {
    local ($_) = shift;
    return 0 unless m,^(?:HTTP/)?(\d+)\.(\d+)$,i;
    $1 * 1000 + $2;
}

sub antique_client {
    my $self = shift;
    ${*$self}{'httpd_client_proto'} < $HTTP_1_0;
}

sub force_last_request {
    my $self = shift;
    ${*$self}{'httpd_nomore'}++;
}

sub head_request {
    my $self = shift;
    ${*$self}{'httpd_head'};
}


sub send_status_line {
    my ($self, $status, $message, $proto) = @_;
    return if $self->antique_client;
    $status  ||= RC_OK;
    $message ||= status_message($status) || "";
    $proto   ||= $HTTP::Daemon::PROTO || "HTTP/1.1";
    print $self "$proto $status $message$CRLF";
}

sub send_crlf {
    my $self = shift;
    print $self $CRLF;
}

sub send_basic_header {
    my $self = shift;
    return if $self->antique_client;
    $self->send_status_line(@_);
    print $self "Date: ", time2str(time), $CRLF;
    my $product = $self->daemon->product_tokens;
    print $self "Server: $product$CRLF" if $product;
}

sub send_header {
    my $self = shift;
    while (@_) {
        my ($k, $v) = splice(@_, 0, 2);
        $v = "" unless defined($v);
        print $self "$k: $v$CRLF";
    }
}

sub send_response {
    my $self = shift;
    my $res  = shift;
    if (!ref $res) {
        $res ||= RC_OK;
        $res = HTTP::Response->new($res, @_);
    }
    my $content = $res->content;
    my $chunked;
    unless ($self->antique_client) {
        my $code = $res->code;
        $self->send_basic_header($code, $res->message, $res->protocol);
        if ($code =~ /^(1\d\d|[23]04)$/) {

            # make sure content is empty
            $res->remove_header("Content-Length");
            $content = "";
        }
        elsif ($res->request && $res->request->method eq "HEAD") {

            # probably OK
        }
        elsif (ref($content) eq "CODE") {
            if ($self->proto_ge("HTTP/1.1")) {
                $res->push_header("Transfer-Encoding" => "chunked");
                $chunked++;
            }
            else {
                $self->force_last_request;
            }
        }
        elsif (length($content)) {
            $res->header("Content-Length" => length($content));
        }
        else {
            $self->force_last_request;
            $res->header('connection', 'close');
        }
        print $self $res->headers_as_string($CRLF);
        print $self $CRLF;    # separates headers and content
    }
    if ($self->head_request) {

        # no content
    }
    elsif (ref($content) eq "CODE") {
        while (1) {
            my $chunk = &$content();
            last unless defined($chunk) && length($chunk);
            if ($chunked) {
                printf $self "%x%s%s%s", length($chunk), $CRLF, $chunk, $CRLF;
            }
            else {
                print $self $chunk;
            }
        }
        print $self "0$CRLF$CRLF" if $chunked;    # no trailers either
    }
    elsif (length $content) {
        print $self $content;
    }
}

sub send_redirect {
    my ($self, $loc, $status, $content) = @_;
    $status ||= RC_MOVED_PERMANENTLY;
    Carp::croak("Status '$status' is not redirect") unless is_redirect($status);
    $self->send_basic_header($status);
    my $base = $self->daemon->url;
    $loc = $HTTP::URI_CLASS->new($loc, $base) unless ref($loc);
    $loc = $loc->abs($base);
    print $self "Location: $loc$CRLF";

    if ($content) {
        my $ct_type = $content =~ /^\s*</ ? "text/html" : "text/plain";
        print $self "Content-Type: $ct_type$CRLF";
    }
    print $self $CRLF;
    print $self $content if $content && !$self->head_request;
    $self->force_last_request;    # no use keeping the connection open
}

sub send_error {
    my ($self, $status, $error) = @_;
    $status ||= RC_BAD_REQUEST;
    Carp::croak("Status '$status' is not an error") unless is_error($status);
    my $mess = status_message($status);
    $error ||= "";
    $mess = <<EOT;
<title>$status $mess</title>
<h1>$status $mess</h1>
$error
EOT
    unless ($self->antique_client) {
        $self->send_basic_header($status);
        print $self "Content-Type: text/html$CRLF";
        print $self "Content-Length: " . length($mess) . $CRLF;
        print $self $CRLF;
    }
    print $self $mess unless $self->head_request;
    $status;
}

sub send_file_response {
    my ($self, $file) = @_;
    if (-d $file) {
        $self->send_dir($file);
    }
    elsif (-f _) {

        # plain file
        local (*F);
        sysopen(F, $file, 0) or return $self->send_error(RC_FORBIDDEN);
        binmode(F);
        my ($mime_type, $file_enc) = guess_media_type($file);
        my ($size, $mtime) = (stat _)[7, 9];
        unless ($self->antique_client) {
            $self->send_basic_header;
            print $self "Content-Type: $mime_type$CRLF";
            print $self "Content-Encoding: $file_enc$CRLF" if $file_enc;
            print $self "Content-Length: $size$CRLF" if $size;
            print $self "Last-Modified: ", time2str($mtime), "$CRLF" if $mtime;
            print $self $CRLF;
        }
        $self->send_file(\*F) unless $self->head_request;
        return RC_OK;
    }
    else {
        $self->send_error(RC_NOT_FOUND);
    }
}

sub send_dir {
    my ($self, $dir) = @_;
    $self->send_error(RC_NOT_FOUND) unless -d $dir;
    $self->send_error(RC_NOT_IMPLEMENTED);
}

sub send_file {
    my ($self, $file) = @_;
    my $opened = 0;
    local (*FILE);
    if (!ref($file)) {
        open(FILE, $file) || return undef;
        binmode(FILE);
        $file = \*FILE;
        $opened++;
    }
    my $cnt = 0;
    my $buf = "";
    my $n;
    while ($n = sysread($file, $buf, 8 * 1024)) {
        last if !$n;
        $cnt += $n;
        print $self $buf;
    }
    close($file) if $opened;
    $cnt;
}

sub daemon {
    my $self = shift;
    ${*$self}{'httpd_daemon'};
}


1;

__END__

=pod

=encoding UTF-8

=head1 NAME

HTTP::Daemon - A simple http server class

=head1 VERSION

version 6.12

=head1 SYNOPSIS

  use HTTP::Daemon;
  use HTTP::Status;

  my $d = HTTP::Daemon->new || die;
  print "Please contact me at: <URL:", $d->url, ">\n";
  while (my $c = $d->accept) {
      while (my $r = $c->get_request) {
      if ($r->method eq 'GET' and $r->uri->path eq "/xyzzy") {
              # remember, this is *not* recommended practice :-)
          $c->send_file_response("/etc/passwd");
      }
      else {
          $c->send_error(RC_FORBIDDEN)
      }
      }
      $c->close;
      undef($c);
  }

=head1 DESCRIPTION

Instances of the C<HTTP::Daemon> class are HTTP/1.1 servers that
listen on a socket for incoming requests. The C<HTTP::Daemon> is a
subclass of C<IO::Socket::IP>, so you can perform socket operations
directly on it too.

Please note that C<HTTP::Daemon> used to be a subclass of C<IO::Socket::INET>.
To support IPv6, it switched the parent class to C<IO::Socket::IP> at version 6.05.
See L</IPv6 SUPPORT> for details.

The accept() method will return when a connection from a client is
available.  The returned value will be an C<HTTP::Daemon::ClientConn>
object which is another C<IO::Socket::IP> subclass.  Calling the
get_request() method on this object will read data from the client and
return an C<HTTP::Request> object.  The ClientConn object also provide
methods to send back various responses.

This HTTP daemon does not fork(2) for you.  Your application, i.e. the
user of the C<HTTP::Daemon> is responsible for forking if that is
desirable.  Also note that the user is responsible for generating
responses that conform to the HTTP/1.1 protocol.

The following methods of C<HTTP::Daemon> are new (or enhanced) relative
to the C<IO::Socket::IP> base class:

=over 4

=item $d = HTTP::Daemon->new

=item $d = HTTP::Daemon->new( %opts )

The constructor method takes the same arguments as the
C<IO::Socket::IP> constructor, but unlike its base class it can also
be called without any arguments.  The daemon will then set up a listen
queue of 5 connections and allocate some random port number.

A server that wants to bind to some specific address on the standard
HTTP port will be constructed like this:

  $d = HTTP::Daemon->new(
           LocalAddr => 'www.thisplace.com',
           LocalPort => 80,
       );

See L<IO::Socket::IP> for a description of other arguments that can
be used to configure the daemon during construction.

=item $c = $d->accept

=item $c = $d->accept( $pkg )

=item ($c, $peer_addr) = $d->accept

This method works the same as the one provided by the base class, but it
returns an C<HTTP::Daemon::ClientConn> reference by default.  If a
package name is provided as argument, then the returned object will be
blessed into the given class.  It is probably a good idea to make that
class a subclass of C<HTTP::Daemon::ClientConn>.

The accept method will return C<undef> if timeouts have been enabled
and no connection is made within the given time.  The timeout() method
is described in L<IO::Socket::IP>.

In list context both the client object and the peer address will be
returned; see the description of the accept method of L<IO::Socket> for
details.

=item $d->url

Returns a URL string that can be used to access the server root.

=item $d->product_tokens

Returns the name that this server will use to identify itself.  This
is the string that is sent with the C<Server> response header.  The
main reason to have this method is that subclasses can override it if
they want to use another product name.

The default is the string "libwww-perl-daemon/#.##" where "#.##" is
replaced with the version number of this module.

=back

The C<HTTP::Daemon::ClientConn> is a subclass of C<IO::Socket::IP>.
Instances of this class are returned by the accept() method
of C<HTTP::Daemon>.  The following methods are provided:

=over 4

=item $c->get_request

=item $c->get_request( $headers_only )

This method reads data from the client and turns it into an
C<HTTP::Request> object which is returned.  It returns C<undef>
if reading fails.  If it fails, then the C<HTTP::Daemon::ClientConn>
object ($c) should be discarded, and you should not try to call this
method again on it.  The $c->reason method might give you some
information about why $c->get_request failed.

The get_request() method will normally not return until the whole
request has been received from the client.  This might not be what you
want if the request is an upload of a large file (and with chunked
transfer encoding HTTP can even support infinite request messages -
uploading live audio for instance).  If you pass a TRUE value as the
$headers_only argument, then get_request() will return immediately
after parsing the request headers and you are responsible for reading
the rest of the request content.  If you are going to call
$c->get_request again on the same connection you better read the
correct number of bytes.

=item $c->read_buffer

=item $c->read_buffer( $new_value )

Bytes read by $c->get_request, but not used are placed in the I<read
buffer>.  The next time $c->get_request is called it will consume the
bytes in this buffer before reading more data from the network
connection itself.  The read buffer is invalid after $c->get_request
has failed.

If you handle the reading of the request content yourself you need to
empty this buffer before you read more and you need to place
unconsumed bytes here.  You also need this buffer if you implement
services like I<101 Switching Protocols>.

This method always returns the old buffer content and can optionally
replace the buffer content if you pass it an argument.

=item $c->reason

When $c->get_request returns C<undef> you can obtain a short string
describing why it happened by calling $c->reason.

=item $c->proto_ge( $proto )

Return TRUE if the client announced a protocol with version number
greater or equal to the given argument.  The $proto argument can be a
string like "HTTP/1.1" or just "1.1".

=item $c->antique_client

Return TRUE if the client speaks the HTTP/0.9 protocol.  No status
code and no headers should be returned to such a client.  This should
be the same as !$c->proto_ge("HTTP/1.0").

=item $c->head_request

Return TRUE if the last request was a C<HEAD> request.  No content
body must be generated for these requests.

=item $c->force_last_request

Make sure that $c->get_request will not try to read more requests off
this connection.  If you generate a response that is not self-delimiting,
then you should signal this fact by calling this method.

This attribute is turned on automatically if the client announces
protocol HTTP/1.0 or worse and does not include a "Connection:
Keep-Alive" header.  It is also turned on automatically when HTTP/1.1
or better clients send the "Connection: close" request header.

=item $c->send_status_line

=item $c->send_status_line( $code )

=item $c->send_status_line( $code, $mess )

=item $c->send_status_line( $code, $mess, $proto )

Send the status line back to the client.  If $code is omitted 200 is
assumed.  If $mess is omitted, then a message corresponding to $code
is inserted.  If $proto is missing the content of the
$HTTP::Daemon::PROTO variable is used.

=item $c->send_crlf

Send the CRLF sequence to the client.

=item $c->send_basic_header

=item $c->send_basic_header( $code )

=item $c->send_basic_header( $code, $mess )

=item $c->send_basic_header( $code, $mess, $proto )

Send the status line and the "Date:" and "Server:" headers back to
the client.  This header is assumed to be continued and does not end
with an empty CRLF line.

See the description of send_status_line() for the description of the
accepted arguments.

=item $c->send_header( $field, $value )

=item $c->send_header( $field1, $value1, $field2, $value2, ... )

Send one or more header lines.

=item $c->send_response( $res )

Write an C<HTTP::Response> object to the
client as a response.  We try hard to make sure that the response is
self-delimiting so that the connection can stay persistent for further
request/response exchanges.

The content attribute of the C<HTTP::Response> object can be a normal
string or a subroutine reference.  If it is a subroutine, then
whatever this callback routine returns is written back to the
client as the response content.  The routine will be called until it
returns an undefined or empty value.  If the client is HTTP/1.1 aware
then we will use chunked transfer encoding for the response.

=item $c->send_redirect( $loc )

=item $c->send_redirect( $loc, $code )

=item $c->send_redirect( $loc, $code, $entity_body )

Send a redirect response back to the client.  The location ($loc) can
be an absolute or relative URL. The $code must be one of the redirect
status codes, and defaults to "301 Moved Permanently"

=item $c->send_error

=item $c->send_error( $code )

=item $c->send_error( $code, $error_message )

Send an error response back to the client.  If the $code is missing a
"Bad Request" error is reported.  The $error_message is a string that
is incorporated in the body of the HTML entity.

=item $c->send_file_response( $filename )

Send back a response with the specified $filename as content.  If the
file is a directory we try to generate an HTML index of it.

=item $c->send_file( $filename )

=item $c->send_file( $fd )

Copy the file to the client.  The file can be a string (which
will be interpreted as a filename) or a reference to an C<IO::Handle>
or glob.

=item $c->daemon

Return a reference to the corresponding C<HTTP::Daemon> object.

=back

=head1 IPv6 SUPPORT

Since version 6.05, C<HTTP::Daemon> is a subclass of C<IO::Socket::IP>
rather than C<IO::Socket::INET>, so that it supports IPv6.

For some reasons, you may want to force C<HTTP::Daemon> to listen on IPv4 addresses only.
Then pass C<Family> argument to C<< HTTP::Daemon->new >>:

  use HTTP::Daemon;
  use Socket 'AF_INET';

  my $d = HTTP::Daemon->new(Family => AF_INET);

=head1 SEE ALSO

RFC 2616

L<IO::Socket::IP>, L<IO::Socket>

=head1 SUPPORT

Bugs may be submitted through L<https://github.com/libwww-perl/HTTP-Daemon/issues>.

There is also a mailing list available for users of this distribution, at
L<mailto:libwww@perl.org>.

There is also an irc channel available for users of this distribution, at
L<C<#lwp> on C<irc.perl.org>|irc://irc.perl.org/#lwp>.

=head1 AUTHOR

Gisle Aas <gisle@activestate.com>

=head1 CONTRIBUTORS

=for stopwords Olaf Alders Ville Skyttä Mark Stosberg Karen Etheridge Shoichi Kaji Chase Whitener Slaven Rezic Zefram Petr Písař Tom Hukins Alexey Tourbin Mike Schilli Bron Gondwana Ian Kilgore Jacob J Ondrej Hanak Perlover Peter Rabbitson Robert Stone Rolf Grossmann Sean M. Burke Spiros Denaxas Steve Hay Todd Lipcon Tony Finch Toru Yamaguchi Yuri Karaban amire80 jefflee john9art murphy phrstbrn ruff Adam Kennedy sasao Sjogren Alex Kapranoff Andreas J. Koenig Bill Mann DAVIDRW Daniel Hedlund David E. Wheeler FWILES Father Chrysostomos Ferenc Erki Gavin Peters Graeme Thompson Hans-H. Froehlich

=over 4

=item *

Olaf Alders <olaf@wundersolutions.com>

=item *

Ville Skyttä <ville.skytta@iki.fi>

=item *

Mark Stosberg <MARKSTOS@cpan.org>

=item *

Karen Etheridge <ether@cpan.org>

=item *

Shoichi Kaji <skaji@cpan.org>

=item *

Chase Whitener <capoeirab@cpan.org>

=item *

Slaven Rezic <slaven@rezic.de>

=item *

Zefram <zefram@fysh.org>

=item *

Petr Písař <ppisar@redhat.com>

=item *

Tom Hukins <tom@eborcom.com>

=item *

Alexey Tourbin <at@altlinux.ru>

=item *

Mike Schilli <mschilli@yahoo-inc.com>

=item *

Bron Gondwana <brong@fastmail.fm>

=item *

Ian Kilgore <iank@cpan.org>

=item *

Jacob J <waif@chaos2.org>

=item *

Ondrej Hanak <ondrej.hanak@ubs.com>

=item *

Perlover <perlover@perlover.com>

=item *

Peter Rabbitson <ribasushi@cpan.org>

=item *

Robert Stone <talby@trap.mtview.ca.us>

=item *

Rolf Grossmann <rg@progtech.net>

=item *

Sean M. Burke <sburke@cpan.org>

=item *

Spiros Denaxas <s.denaxas@gmail.com>

=item *

Steve Hay <SteveHay@planit.com>

=item *

Todd Lipcon <todd@amiestreet.com>

=item *

Tony Finch <dot@dotat.at>

=item *

Toru Yamaguchi <zigorou@cpan.org>

=item *

Yuri Karaban <tech@askold.net>

=item *

amire80 <amir.aharoni@gmail.com>

=item *

jefflee <shaohua@gmail.com>

=item *

john9art <john9art@yahoo.com>

=item *

murphy <murphy@genome.chop.edu>

=item *

phrstbrn <phrstbrn@gmail.com>

=item *

ruff <ruff@ukrpost.net>

=item *

Adam Kennedy <adamk@cpan.org>

=item *

sasao <sasao@yugen.org>

=item *

Adam Sjogren <asjo@koldfront.dk>

=item *

Alex Kapranoff <ka@nadoby.ru>

=item *

Andreas J. Koenig <andreas.koenig@anima.de>

=item *

Bill Mann <wfmann@alum.mit.edu>

=item *

DAVIDRW <davidrw@cpan.org>

=item *

Daniel Hedlund <Daniel.Hedlund@eprize.com>

=item *

David E. Wheeler <david@justatheory.com>

=item *

FWILES <FWILES@cpan.org>

=item *

Father Chrysostomos <sprout@cpan.org>

=item *

Ferenc Erki <erkiferenc@gmail.com>

=item *

Gavin Peters <gpeters@deepsky.com>

=item *

Graeme Thompson <Graeme.Thompson@mobilecohesion.com>

=item *

Hans-H. Froehlich <hfroehlich@co-de-co.de>

=back

=head1 COPYRIGHT AND LICENCE

This software is copyright (c) 1995 by Gisle Aas.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
