#!/usr/bin/perl

# (C) Maxim Dounin

# Tests for nginx mail smtp module.

###############################################################################

use warnings;
use strict;

use Test::More;

use MIME::Base64;
use Socket qw/ CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::SMTP;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()
	->has('mail', plan => 26)
	->run_daemon(\&Test::Nginx::SMTP::smtp_test_daemon)
	->write_file_expand('nginx.conf', <<'EOF')->run();

master_process off;
daemon         off;

events {
    worker_connections  1024;
}

mail {
    proxy_pass_error_message  on;
    auth_http  http://localhost:8080/mail/auth;
    xclient    off;

    server {
        listen     localhost:8025;
        protocol   smtp;
        smtp_auth  login plain none;
    }
}

http {
    access_log    off;

    server {
        listen       localhost:8080;
        server_name  localhost;

        location = /mail/auth {
            set $reply ERROR;

            if ($http_auth_smtp_to ~ example.com) {
                set $reply OK;
            }
            if ($http_auth_pass ~ secret) {
                set $reply OK;
            }

            add_header Auth-Status $reply;
            add_header Auth-Server 127.0.0.1;
            add_header Auth-Port 8026;
            add_header Auth-Wait 1;
            return 204;
        }
    }
}

EOF

###############################################################################

my $s = Test::Nginx::SMTP->new();
$s->check(qr/^220 /, "greeting");

$s->send('EHLO example.com');
$s->check(qr/^250 /, "ehlo");

$s->send('AUTH PLAIN ' . encode_base64("test\@example.com\0\0bad", ''));
$s->check(qr/^5.. /, 'auth plain with bad password');

$s->send('AUTH PLAIN ' . encode_base64("test\@example.com\0\0secret", ''));
$s->ok('auth plain');

# We are talking to backend from this point

$s->send('MAIL FROM:<test@example.com> SIZE=100');
$s->ok('mail from after auth');

$s->send('RSET');
$s->ok('rset');

$s->send('MAIL FROM:<test@xn--e1afmkfd.xn--80akhbyknj4f> SIZE=100');
$s->ok("idn mail from (example.test in russian)");

$s->send('QUIT');
$s->ok("quit");

# Try auth plain with pipelining

$s = Test::Nginx::SMTP->new();
$s->check(qr/^220 /, "greeting");

$s->send('EHLO example.com');
$s->check(qr/^250 /, "ehlo");

$s->send('INVALID COMMAND WITH ARGUMENTS' . CRLF
	. 'RSET');
$s->read();
$s->ok('pipelined rset after invalid command');

$s->send('AUTH PLAIN '
	. encode_base64("test\@example.com\0\0bad", '') . CRLF
	. 'MAIL FROM:<test@example.com> SIZE=100');
$s->read();
$s->ok('mail from after failed pipelined auth');

$s->send('AUTH PLAIN '
	. encode_base64("test\@example.com\0\0secret", '') . CRLF
	. 'MAIL FROM:<test@example.com> SIZE=100');
$s->read();
$s->ok('mail from after pipelined auth');

# Try auth none

$s = Test::Nginx::SMTP->new();
$s->check(qr/^220 /, "greeting");

$s->send('EHLO example.com');
$s->check(qr/^250 /, "ehlo");

$s->send('MAIL FROM:<test@example.com> SIZE=100');
$s->ok('auth none - mail from');

$s->send('RCPT TO:<test@example.com>');
$s->ok('auth none - rcpt to');

$s->send('RSET');
$s->ok('auth none - rset, should go to backend');

# Auth none with pipelining

$s = Test::Nginx::SMTP->new();
$s->check(qr/^220 /, "greeting");

$s->send('EHLO example.com');
$s->check(qr/^250 /, "ehlo");

$s->send('MAIL FROM:<test@example.com> SIZE=100' . CRLF
	. 'RCPT TO:<test@example.com>' . CRLF
	. 'RSET');

$s->ok('pipelined mail from');

$s->ok('pipelined rcpt to');
$s->ok('pipelined rset');

# Connection must stay even if error returned to rcpt to command

$s = Test::Nginx::SMTP->new();
$s->read(); # skip greeting

$s->send('EHLO example.com');
$s->read(); # skip ehlo reply

$s->send('MAIL FROM:<test@example.com> SIZE=100');
$s->read(); # skip mail from reply

$s->send('RCPT TO:<example.com>');
$s->check(qr/^5.. /, "bad rcpt to");

$s->send('RCPT TO:<test@example.com>');
$s->ok('good rcpt to');

# Make sure command splitted into many packets processed correctly

$s = Test::Nginx::SMTP->new();
$s->read();

log_out('HEL');
$s->print('HEL');
$s->send('O example.com');
$s->ok('splitted command');

###############################################################################
