#!/usr/bin/perl

# (C) Andrey Zelenkov
# (C) Nginx, Inc.

# Tests for stream limit_conn module with datagrams.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::Stream qw/ dgram /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/stream stream_limit_conn udp shmem/)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

stream {
    limit_conn_zone  $binary_remote_addr  zone=zone:1m;
    limit_conn_zone  $binary_remote_addr  zone=zone2:1m;

    proxy_responses  1;
    proxy_timeout    1s;

    server {
        listen           127.0.0.1:%%PORT_1_UDP%% udp;
        proxy_pass       127.0.0.1:%%PORT_0_UDP%%;

        limit_conn       zone 1;
        proxy_responses  2;
    }

    server {
        listen           127.0.0.1:%%PORT_2_UDP%% udp;
        proxy_pass       127.0.0.1:%%PORT_0_UDP%%;
        limit_conn       zone2 1;
    }

    server {
        listen           127.0.0.1:%%PORT_3_UDP%% udp;
        proxy_pass       127.0.0.1:%%PORT_0_UDP%%;
        limit_conn       zone 5;
    }

    server {
        listen           127.0.0.1:%%PORT_4_UDP%% udp;
        proxy_pass       127.0.0.1:%%PORT_1_UDP%%;
        limit_conn       zone2 1;
    }

    server {
        listen           127.0.0.1:%%PORT_5_UDP%% udp;
        proxy_pass       127.0.0.1:%%PORT_1_UDP%%;
        limit_conn       zone 1;
    }
}

EOF

$t->try_run('no stream udp')->plan(9);
$t->run_daemon(\&udp_daemon, $t);
$t->waitforfile($t->testdir . '/' . port(0));

###############################################################################

# same and other zones

my $s = dgram('127.0.0.1:' . port(1));

is($s->io('1'), '1', 'passed');

# if not all responses were sent to client, then new request
# in same socket will be treated as new connection

is($s->io('1', read_timeout => 0.1), '', 'rejected new connection');
is(dgram('127.0.0.1:' . port(1))->io('1', read_timeout => 0.1), '',
	'rejected same zone');
is(dgram('127.0.0.1:' . port(2))->io('1'), '1', 'passed different zone');
is(dgram('127.0.0.1:' . port(3))->io('1'), '1', 'passed same zone unlimited');

sleep 1;	# waiting for proxy_timeout to expire

is($s->io('2', read => 2), '12', 'new connection after proxy_timeout');

is(dgram('127.0.0.1:' . port(1))->io('2', read => 2), '12', 'passed 2');

# zones proxy chain

is(dgram('127.0.0.1:' . port(4))->io('1'), '1', 'passed proxy');
is(dgram('127.0.0.1:' . port(5))->io('1', read_timeout => 0.1), '',
	'rejected proxy');

###############################################################################

sub udp_daemon {
	my $t = shift;

	my $server = IO::Socket::INET->new(
		Proto => 'udp',
		LocalAddr => '127.0.0.1:' . port(0),
		Reuse => 1,
	)
		or die "Can't create listening socket: $!\n";

	# signal we are ready

	open my $fh, '>', $t->testdir() . '/' . port(0);
	close $fh;

	while (1) {
		$server->recv(my $buffer, 65536);
		$server->send($_) for (1 .. $buffer);
	}
}

###############################################################################
