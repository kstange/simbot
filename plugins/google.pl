# SimBot Find Plugin
#
# Copyright (C) 2003-05, Kevin M Stange <kevin@simguy.net>
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

package SimBot::plugin::find;

use strict;
use warnings;

# We need these to work with HTML and HTTP
use LWP::UserAgent;
use HTML::Entities;

# GOOGLE_FIND: Prints a URL returned by google's I'm Feeling Lucky.
sub google_find {
    my ($kernel, $nick, $channel, @terms) = @_;
    shift(@terms);
    my $query = "@terms";

    &SimBot::debug(3, "google: Got request from " . $nick . ".\n");

	if (!$query) {
		&SimBot::send_message($channel, "$nick: Nothing was found.  I didn't look, but I think that was a safe bet.");
		return;
	}

    $query =~ s/\&/\%26/g;
    $query =~ s/\%/\%25/g;
    $query =~ s/\+/\%2B/g;
    $query =~ s/\s/+/g;
    my $url = "http://www.google.com/search?q=" . $query . "&btnI=1&safe=active";
    my $useragent = LWP::UserAgent->new(requests_redirectable => undef);
    $useragent->agent(SimBot::PROJECT . "/" . SimBot::VERSION);
    $useragent->timeout(5);
    my $request = HTTP::Request->new(GET => $url);
    my $response = $useragent->request($request);
    if ($response->previous) {
		if ($response->previous->is_redirect) {
			&SimBot::send_message($channel, "$nick: " . $response->request->uri());
		} else {
			&SimBot::send_message($channel, "$nick: An unknown error occured retrieving results.");
		}
    } elsif (!$response->is_error) {
		# Let's use the calculator!
		if ($response->content =~ m|/images/calc_img\.gif|) {
			$response->content =~ m|<td nowrap><font size=\+1><b>(.*?)</b></td>|;
			# We can't just take $1 because it might have HTML in it
			my $result = $1;
			$result =~ s|<sup>(.*?)</sup>|^$1|g;
			$result =~ s|<font size=-2> </font>|,|g;
			$result = HTML::Entities::decode($result);
			&SimBot::send_message($channel, "$nick: $result");
		} elsif ($response->content =~ m|Definitions of <b>(.*?)</b> on the Web:|) {
			my $term = $1;
			if ($response->content =~ m/<li>(.*?)(<br>|<li>)/) {
				my $result = $1;
				$result =~ s|[\n\r]||g;
				$result = HTML::Entities::decode($result);
				&SimBot::send_pieces($channel, "$nick: ", "\"$term\" is $result");
			} else {
				&SimBot::send_pieces($channel, "$nick: Sorry.  I had trouble understanding the results.  You can try if you want: $url");
			}
		} elsif ($response->content =~ m|No definitions were found for|) {
			&SimBot::send_message($channel, "$nick: Making up words again?");
        } elsif ($response->content =~ m|/images/package\.gif|) {
            # Let's track a package!
            my ($result) = $response->content =~ m|<td valign=top><a href="(\S+)">Track|;
            &SimBot::send_message($channel, "$nick: $result");
        } elsif ($response->content =~ m|<a href="/reviews\?|) { #"
            # Movies!
            
            # Let's count the stars...
            my @star_list = $response->content =~ m{<nobr><img src="/images/showtimes-star-(on|off)\.gif" border=0><img src="/images/showtimes-star-(on|off)\.gif" border=0><img src="/images/showtimes-star-(on|off)\.gif" border=0><img src="/images/showtimes-star-(on|off)\.gif" border=0><img src="/images/showtimes-star-(on|off)\.gif" border=0></nobr>};
            my $stars;
            if   ($star_list[4] eq 'on')    { $stars = 5; }
            elsif($star_list[3] eq 'on')    { $stars = 4; }
            elsif($star_list[2] eq 'on')    { $stars = 3; }
            elsif($star_list[1] eq 'on')    { $stars = 2; }
            elsif($star_list[0] eq 'on')    { $stars = 1; }
            else                            { $stars = 0; }
            
            my ($url, $title) = $response->content =~ m|<td valign=top><a href="(/reviews?\S+)">(.*?)</a>|;
            $url = 'http://www.google.com' . $url;
            
            $title =~ s|</?b>||ig;
            $title = HTML::Entities::decode($title);
            
            &SimBot::send_message($channel, "$nick: $title, "
                . ($stars == 1 ? 'one star' : "$stars stars")
                . ', ' . $url);
            
		} else {
			&SimBot::send_message($channel, "$nick: Nothing was found.");
		}
    } else {
		&SimBot::send_message($channel, "$nick: Sorry, I could not access Google.");
	}
}

# Register Plugin
&SimBot::plugin_register(plugin_id   => "find",
						 plugin_desc => "Searches Google with \"I'm Feeling Lucky\"",

						 event_plugin_call => \&google_find,
						 );
