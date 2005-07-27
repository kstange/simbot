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

use constant WEB_PORT => 8090;

our $aliases;

$aliases = POE::Component::Server::HTTP->new(
    Alias => 'simbot_plugin_httpd',
    Port => WEB_PORT,
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
    
    &SimBot::debug(3, 'httpd: handling request for ' . $request->uri . "\n");
    
    my $requested_page = $request->uri;
    $requested_page =~ s|^http://(.*?)/|/|;
    
    if(defined $SimBot::hash_plugin_httpd_pages{$requested_page}) {
        my $handler = $SimBot::hash_plugin_httpd_pages{$requested_page}->{'handler'};
        &$handler($request, $response);
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

sub messup_httpd {
    $SimBot::hash_plugin_httpd_pages{'/test'} = {
        'title' => 'Goes nowhere, does nothing!',
        'handler' => sub {},
    }
    #&add_page('/test', 'Goes nowhere, does nothing!', sub {});
}

sub cleanup_httpd {
    POE::Kernel->call($aliases->{httpd}, 'shutdown');
}

&SimBot::plugin_register(
    plugin_id => 'httpd',
    event_plugin_load => \&messup_httpd,
    event_plugin_unload => \&cleanup_httpd,
);