###
#  SimBot TinyURL Plugin
#
# DESCRIPTION:
#   The TinyURL plugin watches chat for URLs pointing to TinyURL
#   style services. When one is recognized, it looks up the URL, and
#   announces in chat where the URL points.
#
# COPYRIGHT:
#   Copyright (C) 2004, Pete Pearson
#
#   This program is free software; you can redistribute it and/or modify
#   under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#   
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#   
#   You should have received a copy of the GNU General Public License
#   along with this program; if not, write to the Free Software
#   Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA
#
# TODO:
#   * common affiliate links should be recognized, and the affiliate
#     part should not be left out when shortening links (possibly
#     resulting in output looking like
#     "...links to: somesite.com/f...someaffiliate...sdf.php"
#     or should it look like
#     "links to somesite.com (Affiliate: someaffiliate)" instead?
#   * We probably should use the actual service's name instead of
#     always calling it TinyURL even if it is really url123.com

package SimBot::plugin::tinyurl;

use warnings;
use strict;

use vars qw( @match_rules %urlcache );

use LWP::UserAgent;

# these are matching rules for various tinyurl style services
# they should be qr// regular expressions. The entire URL needs to be
# in ().
@match_rules = (
    qr%(http://tinyurl\.(com|co\.uk)/[\S]+)%,
    qr%(http://([\S]+\.)?url123\.com/[\S]+)%,
    qr%(http://[\S+]\.v3\.net)%,
);
# makeashorterlink.com aka masl.to doesn't work as it doesn't use
# http redirects. Doesn't matter, as it warns you where you're about to
# go so a warning in chat isn't necessary


# munge_url
# takes in a URL, returns a URL.
# does any URL replacements necessary to get a URL that will return
# a useful Location header instead of one that redirects to another
# redirect
sub munge_url {
    $_ = $_[0];
    
    s|http://tinyurl.com/|http://redirecting.tinyurl.com/redirect.php?num=|;
    
    return $_;
}

# handle_chat is called by simbot whenever something is said.
sub handle_chat {
    my (undef, $nick, $channel, undef, $content) = @_;
    foreach my $cur_rule (@match_rules) {
        if($content =~ /$cur_rule/) {
            my $url = munge_url($1);
            &SimBot::debug(3, "tinyurl: Looking up ${url}\n");
            
            my $useragent =
                LWP::UserAgent->new(requests_redirectable => undef);
            $useragent->agent(SimBot::PROJECT . '/' . SimBot::VERSION);
            $useragent->timeout(5);
            my $request = HTTP::Request->new(GET => $url);
            my $response = $useragent->request($request);
            if($response->previous) {
                if($response->previous->is_redirect) {
                    &SimBot::send_message($channel, 'TinyURL points to '
                            . &shorten_url($response->request->uri()));
                } else {
                    &SimBot::debug(3, "   failed! (no redirect)\n");           
                }
            } else {
                &SimBot::debug(3, "   failed!\n");
                warn $response->content;
            }
            return;
        }
    }       
}

# shorten_url takes in a URL, returns a string
# Here is where we replace long URLs with something that still
# gets the point across.
sub shorten_url {
    my $url = $_[0];
    my $desc = '';
    
    $url =~ s|^http://||i;
    if   ($url =~ s|^https://||i)   { $desc .= ' (Secure)'; }
    elsif($url =~ s|^(\w+)://||i)   { $desc .= " ($1)"; }
    
    # grab usernames, passwords
    if($url =~ s|^((\S+?)(:(\S+))?)@||) {
        if(defined $3)  { $desc .= " (user: $2 pass: $4)"; }
        else            { $desc .= " (user: $2)"; }
    }
    
    $url =~ s%^(www|web)\.%%i;
    
    if(length $url > 100) {
        $url =~ s|\?(\S+)$|\?...|;
        if($url =~ m|^(\S+?)/(.*)/(\S+)$| && length $2 > 3) {
            $url = "$1/.../$3";
        }
    }
    
    $url =~ s%/$%%;
    return $url . $desc;
}

&SimBot::plugin_register(
    plugin_id   => 'tinyurl',
#    event_plugin_load   => \&messup_tinyurl,
#    event_plugin_unload => \&cleanup_tinyurl,
    event_channel_message   => \&handle_chat,
);
