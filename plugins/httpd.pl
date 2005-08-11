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
use POE::Component::Server::TCP;
use POE::Filter::HTTPD;
use HTTP::Status;
use HTML::Template::Pro;

our $aliases;
use vars qw( $kernel );

POE::Component::Server::TCP->new(
    Alias => 'web_server',
    Port  => (defined &SimBot::option('plugin.httpd', 'port')
              ? &SimBot::option('plugin.httpd', 'port')
              : 8000),
    ClientFilter => 'POE::Filter::HTTPD',
    
    ClientInput => \&index_handler,
);

sub index_handler {
    my ($kernel, $heap, $request) = @_[KERNEL, HEAP, ARG0];
#    my ($request, $response) = @_;

    if($request->isa("HTTP::Response")) {
        # We couldn't parse the client's request... shouldn't happen...
        # POE::Filter::HTTPD generated a response for us, isn't that kind?
        # Let's send it on its way...
        $heap->{client}->put($request);
        return;
    }
    
    my $response = HTTP::Response->new(200);
    
    my ($req_root) = $request->uri =~ m|^/([^\?]*)|;
    
    &SimBot::debug(3, 'httpd: handling request for ' . $request->uri . ", req root $req_root\n");
    my $code = 500; # An error by default.
    
    if($req_root && defined $SimBot::hash_plugin_httpd_pages{$req_root}) {
        my $handler = $SimBot::hash_plugin_httpd_pages{$req_root}->{'handler'};
        $code = &$handler($request, $response, \&get_template);
        
    } else {
        if($req_root) { # a page was requested, but we don't have it.
            $code = RC_NOT_FOUND;
        } else {
            # do the index page
            my $msg;
            $msg .= "<ul>\n";
            foreach my $url (keys %SimBot::hash_plugin_httpd_pages) {
                my $title = $SimBot::hash_plugin_httpd_pages{$url}->{'title'};
                
                $msg .= qq(<li><a href="$url">$title</a></li>\n);
            }
            $msg .= "</ul>\n";
            
            $code = RC_OK;
            $response->push_header("Content-Type", "text/html");
            
            my $template = &get_template('base');
            $template->param(
                title => 'Index',
                content => $msg,
            );
            $response->content($template->output());
        }
    }
    
    if(!defined $code || int $code >= 300 || int $code < 200) {
        # Plugin gave us no return value, or an error code, or an absurd number
        # make the error page.
        if(!defined $code || $code < 200 || $code >= 600) {
            # no code, or code absurd.
            $code = RC_INTERNAL_SERVER_ERROR;
        }
        my $err_template = &get_template("error.$code");
        if(!defined $err_template) { $err_template = &get_template('error.500'); }
        if(!defined $err_template) {
            $response->code(RC_INTERNAL_SERVER_ERROR);
            $response->content("An internal error prevented us from completing your request, and no template was available for the error message.");
        } else {
            $response->code($code);
            $err_template->param(
                request_url => $request->uri,
            );
            my $base_template = &get_template('base');
            $base_template->param(
                content => $err_template->output(),
                title => "$code " . status_message($code),
            );
            $response->content($base_template->output());
        }

    }
    
    $response->code($code);
    $heap->{client}->put($response);
    $kernel->yield('shutdown');
}

sub get_template {
    my $template = $_[0];
    my $file_name;
    
    if(-r "templates/${template}.local.tmpl") {
        $file_name = "templates/${template}.local.tmpl";
    } elsif(-r "templates/${template}.default.tmpl") {
        $file_name = "templates/${template}.default.tmpl";
    } else {
        &SimBot::debug(&SimBot::DEBUG_WARN, "httpd: No template $template available!\n");
        return;
    }
    
    my $templ_obj = HTML::Template->new( filename => $file_name,
        die_on_bad_params => 0,
        case_sensitive => 1,
        loop_context_vars => 1,
    );
    $templ_obj->param(
        sb_version => &SimBot::PROJECT . ' ' . &SimBot::VERSION,
        sb_link => &SimBot::HOME_PAGE,
    );
    return $templ_obj;
}

sub admin_page {
    my ($request, $response) = @_;
    
    if(!defined &SimBot::option('plugin.httpd', 'admin_pass')) {
        &SimBot::debug(&SimBot::DEBUG_WARN, "httpd: in admin_page with no password defined!\n");
        return 500; # internal server error
    }
    
    if(!defined $request->authorization_basic) {
        $response->www_authenticate('Basic realm="simbot admin"');
        $response->code(RC_UNAUTHORIZED);
        return RC_UNAUTHORIZED;
    }
    my ($user, $pass) = $request->authorization_basic;
    if($user ne &SimBot::option('plugin.httpd', 'admin_user')
        || $pass ne &SimBot::option('plugin.httpd', 'admin_pass')) {
        
        $response->www_authenticate('Basic realm="simbot admin"');
        $response->code(RC_UNAUTHORIZED);
        return RC_UNAUTHORIZED;
    }
    my $msg;
    my $say;
    
    if($request->uri =~ m|\?restart$|) {
        if(!defined $kernel) {
            warn "Trying to restart simbot without a kernel";
        }
        POE::Kernel->post('simbot', 'restart', "web admin");
        $response->code(RC_OK);
        $response->content('OK, restarting');
        return RC_OK;
    } elsif(($say) = $request->uri =~ m|\?say=(\S+)$|) {
        $say =~ s/\+/ /g;
        $say =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
        &SimBot::debug(3, "Speech requested by web admin\n");
        &SimBot::send_message(&SimBot::option('network', 'channel'),
            $say);
    } elsif(($say) = $request->uri =~ m|\?action=(\S+)$|) {
        $say =~ s/\+/ /g;
        $say =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
        &SimBot::debug(3, "Action requested by web admin\n");
        &SimBot::send_action(&SimBot::option('network', 'channel'),
            $say);
    }
    $msg .= '<ul><li><a href="/admin?restart">Restart Simbot</a></li>';
    $msg .= '<li><form method="get" action=""><label for="say">Say: </label><input name="say"/></form></li>';
    $msg .= '<li><form method="get" action=""><label for="action">Action: </label><input name="action"/></form></li>';
    $msg .= '</ul>';
    $response->code(RC_OK);
    
    my $template = &get_template('base');
    $template->param(
        title => 'Admin',
        content => $msg,
    );
    $response->content($template->output());
    return RC_OK;
}

sub messup_httpd {    
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
}

sub cleanup_httpd {
    &SimBot::debug(3, "httpd: Shutting down...");
    POE::Kernel->call('web_server', 'shutdown');
    &SimBot::debug(3, " ok\n");
}

&SimBot::plugin_register(
    plugin_id => 'httpd',
    event_plugin_load => \&messup_httpd,
    event_plugin_unload => \&cleanup_httpd,
);
