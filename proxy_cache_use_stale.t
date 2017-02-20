#!/usr/bin/perl

# (C) Sergey Kandaurov
# (C) Nginx, Inc.

# Tests for http proxy cache, proxy_cache_use_stale.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx qw/ :DEFAULT http_end /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http proxy cache rewrite limit_req/)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    proxy_cache_path   %%TESTDIR%%/cache  levels=1:2  keys_zone=NAME:1m;

    limit_req_zone  $binary_remote_addr  zone=one:1m  rate=15r/m;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
            proxy_pass    http://127.0.0.1:8081;

            proxy_cache   NAME;

            proxy_cache_key  $uri;

            proxy_cache_revalidate  on;

            proxy_cache_background_update  on;

            add_header X-Cache-Status $upstream_cache_status;

            location /t4.html {
                proxy_pass    http://127.0.0.1:8081/t.html;

                proxy_cache_revalidate  off;
            }

            location /t5.html {
                proxy_pass    http://127.0.0.1:8081/t.html;

                proxy_cache_background_update  off;
            }

            location /updating/ {
                proxy_pass    http://127.0.0.1:8081/;

                proxy_cache_use_stale  updating;
            }

            location /t8.html {
                proxy_pass    http://127.0.0.1:8081/t.html;

                proxy_cache_valid  1s;
            }
        }
    }
    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        add_header Cache-Control $http_x_cache_control;

        if ($arg_e) {
            return 500;
        }

        location / { }

        location /t6.html {
            limit_req zone=one burst=2;
        }
    }
}

EOF

$t->write_file('t.html', 'SEE-THIS');
$t->write_file('tt.html', 'SEE-THIS');
$t->write_file('t2.html', 'SEE-THIS');
$t->write_file('t3.html', 'SEE-THIS');
$t->write_file('t6.html', 'SEE-THIS');

$t->try_run('no proxy_cache_background_update')->plan(25);

###############################################################################

like(get('/t.html', 'max-age=1, stale-if-error=5'), qr/MISS/, 'stale-if-error');
like(http_get('/t.html?e=1'), qr/HIT/, 's-i-e - cached');

like(get('/t2.html', 'max-age=1, stale-while-revalidate=10'), qr/MISS/,
	'stale-while-revalidate');
like(http_get('/t2.html'), qr/HIT/, 's-w-r - cached');

get('/tt.html', 'max-age=1, stale-if-error=2');
get('/t3.html', 'max-age=1, stale-while-revalidate=2');
get('/t4.html', 'max-age=1, stale-while-revalidate=2');
get('/t5.html', 'max-age=1, stale-while-revalidate=2');
get('/t6.html', 'max-age=1, stale-while-revalidate=2');
get('/updating/t.html', 'max-age=1');
get('/updating/t2.html', 'max-age=1, stale-while-revalidate=2');
get('/t8.html', 'stale-while-revalidate=10');

sleep 2;

like(http_get('/t.html?e=1'), qr/STALE/, 's-i-e - stale');
like(http_get('/tt.html?e=1'), qr/STALE/, 's-i-e - stale 2');
like(http_get('/t.html'), qr/REVALIDATED/, 's-i-e - revalidated');

like(http_get('/t2.html?e=1'), qr/STALE/, 's-w-r - revalidate error');
like(http_get('/t2.html'), qr/STALE/, 's-w-r - stale while revalidate');
like(http_get('/t2.html'), qr/HIT/, 's-w-r - revalidated');

like(get('/t4.html', 'max-age=1, stale-while-revalidate=2'), qr/STALE/,
	's-w-r - unconditional revalidate');
like(http_get('/t4.html'), qr/HIT/, 's-w-r - unconditional revalidated');

like(http_get('/t5.html?e=1'), qr/STALE/,
	's-w-r - foreground revalidate error');
like(http_get('/t5.html'), qr/REVALIDATED/, 's-w-r - foreground revalidated');

# UPDATING while s–w-r

$t->write_file('t6.html', 'SEE-THAT');

my $s = get('/t6.html', 'max-age=1, stale-while-revalidate=2', start => 1);
like(http_get('/t6.html'), qr/UPDATING.*SEE-THIS/s, 's-w-r - updating');
like(http_end($s), qr/STALE.*SEE-THIS/s, 's-w-r - updating stale');
like(http_get('/t6.html'), qr/HIT.*SEE-THAT/s, 's-w-r - updating revalidated');

# stale-while-revalidate with proxy_cache_use_stale updating

like(http_get('/updating/t.html'), qr/STALE/,
	's-w-r - use_stale updating stale');
like(http_get('/updating/t.html'), qr/HIT/,
	's-w-r - use_stale updating revalidated');

# stale-while-revalidate with proxy_cache_valid

like(http_get('/t8.html'), qr/STALE/, 's-w-r - proxy_cache_valid revalidate');
like(http_get('/t8.html'), qr/HIT/, 's-w-r - proxy_cache_valid revalidated');

sleep 2;

like(http_get('/t2.html?e=1'), qr/STALE/, 's-w-r - stale after revalidate');
like(http_get('/t3.html?e=1'), qr/ 500 /, 's-w-r - ceased');
like(http_get('/tt.html?e=1'), qr/ 500 /, 's-i-e - ceased');
like(http_get('/updating/t2.html'), qr/STALE/,
	's-w-r - overriden with use_stale updating');

###############################################################################

sub get {
	my ($url, $extra, %extra) = @_;
	return http(<<EOF, %extra);
GET $url HTTP/1.1
Host: localhost
Connection: close
X-Cache-Control: $extra

EOF
}

###############################################################################
