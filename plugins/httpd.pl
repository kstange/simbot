# SimBot HTTPD plugin
#
# Copyright (C) 2005 Pete Pearson
#
# This program is free software; you can redistribute and/or modify it
# under the terms of version 2 of the GNU General Public License as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

package SimBot::plugin::httpd;

use warnings;
use strict;

use POE;
use POE::Component::Server::HTTP;
use HTTP::Status;

our $aliases;
#our $kernel;
use vars qw( $kernel );

$aliases = POE::Component::Server::HTTP->new(
    Alias => 'simbot_plugin_httpd',
    Port => (defined &SimBot::option('plugin.httpd', 'port')
                ? &SimBot::option('plugin.httpd', 'port')
                : 8000),
    ContentHandler => {
        '/' => \&index_handler,
    },
    Headers => {
        Server => 'SimBot',
    },
);

sub index_handler {
    # build and display a index of what is available
    my ($request, $response) = @_;    
    
    my ($req_root) = $request->uri =~ m|^http://.*?/([^/\?]*)|;
    
    &SimBot::debug(3, 'httpd: handling request for ' . $request->uri . ", req root $req_root\n");
    
    if(defined $SimBot::hash_plugin_httpd_pages{$req_root}) {
        my $handler = $SimBot::hash_plugin_httpd_pages{$req_root}->{'handler'};
        &$handler($request, $response);
        
        if(!defined $response->content
            || length $response->content == 0) {
            # Hey! Our plugin didn't do anything useful.
            $response->code(RC_INTERNAL_SERVER_ERROR);
            $response->content("something's broken");
            # FIXME: We need error pages...
        } elsif(!defined $response->code) {
            $response->code(RC_OK); # assume everything's OK
        }
        
        return;
    }
    
    my $msg = &page_header('SimBot');
    $msg .= "<ul>\n";
    foreach my $url (keys %SimBot::hash_plugin_httpd_pages) {
        my $title = $SimBot::hash_plugin_httpd_pages{$url}->{'title'};
        
        $msg .= qq(<li><a href="$url">$title</a>\n);
    }
    $msg .= "</ul>\n";
    
    $response->code(RC_OK);
    $response->push_header("Content-Type", "text/html");
    $response->content($msg);
}

sub page_header {
    my ($title) = @_;
    
    return <<EOT;
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN"
    "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml"><head>
<link rel="generator" href="http://simbot.sf.net/" />
<title>$title</title>
</head>
<body>
EOT
    
}

sub admin_page {
    my ($request, $response) = @_;
    
    if(!defined &SimBot::option('plugin.httpd', 'admin_pass')) {
        die "In admin_page with no password!";
    }
    
    if(!defined $request->authorization_basic) {
        $response->www_authenticate('Basic realm="simbot admin"');
        $response->code(RC_UNAUTHORIZED);
        return;
    }
    my ($user, $pass) = $request->authorization_basic;
    if($user ne &SimBot::option('plugin.httpd', 'admin_user')
        || $pass ne &SimBot::option('plugin.httpd', 'admin_pass')) {
        
        $response->www_authenticate = 
            'Basic realm="simbot admin"';
        $response->code(RC_UNAUTHORIZED);
        return;
    }
    my $msg = &page_header('SimBot Admin');
    
    
    if($request->uri =~ m|\?restart$|) {
        if(!defined $kernel) {
            warn "Trying to restart simbot without a kernel";
        }
        $kernel->post('simbot', 'restart', "web admin");
        return;
    } elsif(my ($say) = $request->uri =~ m|\?say=(\S+)$|) {
        $say =~ s/\+/ /g;
        $say =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
        &SimBot::debug(3, "Speech requested by web admin\n");
        &SimBot::send_message(&SimBot::option('network', 'channel'),
            $say);
    } elsif(my ($say) = $request->uri =~ m|\?action=(\S+)$|) {
        $say =~ s/\+/ /g;
        $say =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
        &SimBot::debug(3, "Action requested by web admin\n");
        &SimBot::send_action(&SimBot::option('network', 'channel'),
            $say);
    }
    $msg .= '<ul><li><a href="/admin?restart">Restart Simbot</a></li>';
    $msg .= '<li><form method="get" action=""><label for="say">Say: </label><input name="say"/></form></li>';
    $msg .= '<li><form method="get" action=""><label for="action">Action: </label><input name="action"/></form></li>';
    $response->code(RC_OK);
    $response->content($msg);
}

sub messup_httpd {
    $kernel = $_[0];
    
    if(defined &SimBot::option('plugin.httpd', 'admin_user')
        && length &SimBot::option('plugin.httpd', 'admin_user') > 4
        && defined &SimBot::option('plugin.httpd', 'admin_pass')
        && length &SimBot::option('plugin.httpd', 'admin_pass') > 4)
    {    
        $SimBot::hash_plugin_httpd_pages{'admin'} = {
            'title' => 'SimBot Administration',
            'handler' => \&admin_page,
        };
    }
    
    $SimBot::hash_plugin_httpd_pages{'fiveohoh'} = {
        'title' => 'Internal Server Error Generation Department',
        'handler' => sub {},
    };
}

sub cleanup_httpd {
    $kernel->call($aliases->{httpd}, 'shutdown');
    undef $aliases;
}

&SimBot::plugin_register(
    plugin_id => 'httpd',
    event_plugin_load => \&messup_httpd,
    event_plugin_unload => \&cleanup_httpd,
);