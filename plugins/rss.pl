###
#  SimBot RSS Plugin
#
# DESCRIPTION:
#   This plugin announces to the channel when some web site using RSS
#   updates.
#
# REQUIRES:
#   * XML::RSS
#   * POE::Component::Client::HTTP
#   * HTML::Entities
#
# COPYRIGHT:
#   Copyright (C) 2004, Pete Pearson <http://fourohfour.info/>
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
#   * Find a better way to detect new posts in feeds
#   * Make rss feed IDs case insensitive
#

package SimBot::plugin::rss;

use strict;
use warnings;
use XML::RSS;
use HTML::Entities;
use POE;
use POE::Component::Client::HTTP;
use HTTP::Request::Common qw(GET POST);
use HTTP::Status;
use vars qw( %mostRecentPost %feeds %announce_feed $session );
use Encode;

use constant CHANNEL => &SimBot::option('network', 'channel');
use constant FEED_TITLE_STYLE => &SimBot::option('plugin.rss','title_style');
use constant EXPIRE => (&SimBot::option('plugin.rss', 'expire') ?
						&SimBot::option('plugin.rss', 'expire') : 3600);

### messup_rss
# This runs when simbot loads. We need to make sure we know the most
# recent post on each feed at this time so when we update we can
# announce only new stuff.
sub messup_rss {
    foreach my $cur_feed
            (&SimBot::options_in_section('plugin.rss.feeds')) {
        $feeds{$cur_feed}=&SimBot::option('plugin.rss.feeds',
                                          $cur_feed);
        $announce_feed{$cur_feed} = 0;
    }
    foreach my $cur_feed
            (split(/,/, &SimBot::option('plugin.rss', 'announce'))) {
        $announce_feed{$cur_feed} = 1;
    }

    POE::Component::Client::HTTP->spawn
		( Alias => 'ua',
		  Timeout => 120,
		  Agent => SimBot::PROJECT . "/" . SimBot::VERSION,
       );

    $session = POE::Session->create(
        inline_states => {
            _start          => \&do_rss,
            do_rss          => \&do_rss,
            got_response    => \&got_response,
            announce_top    => \&announce_top,
            latest_headlines
                            => \&latest_headlines,
            shutdown        => \&shutdown,
        }
    );
    1;
}

### cleanup_rss
# This runs when simbot wants us to die.
sub cleanup_rss {
    $_[0]->post($session, 'shutdown');
}

### shutdown
# This is run when POE tells us to die.
sub shutdown {
    $_[KERNEL]->alarm_remove_all();
}

### do_rss
# This is run on a timer, once an hour or as specified by the EXPIRE
# option, to fetch new data and, if there is anything new, announce it.
sub do_rss {
    my $kernel = $_[KERNEL];
    my (@newPosts, $title, $request, $file);
    my $rss = new XML::RSS;
    &SimBot::debug(3, "rss: Updating cache...\n");

    foreach my $curFeed (keys %feeds) {
		if($announce_feed{$curFeed}) {
			my $mtime = 0;
			$request = HTTP::Request->new(GET => $feeds{$curFeed});
            $file = "caches/${curFeed}.xml";
			if(-e $file) {
                $mtime = (stat($file))[9];
                $request->if_modified_since($mtime);
            }
			# Fetch the file when one of the following is true:
			#  - We are scheduled to update all files (not initial
			#    fetch).
			#  - The file we have is expired.
			#  - We have no cached version of this file.
			if (defined $mostRecentPost{$curFeed} ||
				!-e $file || $mtime + EXPIRE <= time) {
				$kernel->post( 'ua' => 'request', 'got_response',
							   $request, $curFeed);

			# If the file we have is not expired, we still need to find
			# the most recent post so we have a reference point for later
			# updates. This should only run if all of these conditions
			# are met:
			#  - We have a cached version of this file.
			#  - The file we have is not expired.
			#  - We have not yet found the most recent post (initial
			#    fetch).
			} else {
				&SimBot::debug(4,
				        "rss:   loading up to date cache of $curFeed\n");
				if(eval { $rss->parsefile($file); }) {
					if(defined $rss->{'items'}->[0]->{'guid'}) {
						$mostRecentPost{$curFeed}
						= $rss->{'items'}->[0]->{'guid'};
					} else {
						$mostRecentPost{$curFeed}
						= $rss->{'items'}->[0]->{'link'};
					}
				} else {
					&SimBot::debug(1, "rss:  Parse error in $file: $@");
				}
			}
        }
    }
    $kernel->delay(do_rss => EXPIRE);
}

### got_response
# This is run whenever we have retrieved a RSS feed. We dump it
# to disk.
sub got_response {
    my ($kernel, $request_packet, $response_packet)
        = @_[ KERNEL, ARG0, ARG1 ];
    my (@newPosts, $title, $link, $file);
    my ($curFeed, $nick) = split(/!!/, $request_packet->[1]);
    my $response = $response_packet->[0];
    my $rss = new XML::RSS;
    $file = "caches/${curFeed}.xml";
    &SimBot::debug((($response->code >= 400) ? 1 : 4),
				   "rss:   fetching feed for $curFeed: "
				   . $response->status_line . "\n");

    if($response->code == RC_NOT_MODIFIED) {
        # File wasn't modified. We touch the file so we don't
        # request it again for an hour
        my $now = time;
        utime($now, $now, $file);
    } elsif($response->is_success) {
        if(open(OUT, ">$file")) {
            print OUT $response->content;
            close(OUT);
        } else {
            &SimBot::debug(1,
                    "rss:  Could not open $file for writing: $!\n");
            if(defined $nick) {
                &SimBot::send_message(CHANNEL, "$nick: Sorry, an error has occurred. Please ask the bot's administrator to look in the console for the error message.");
            }
            return;
        }
	}

    if(defined $nick) {
        $kernel->yield('announce_top', $curFeed, $nick, CHANNEL);
		return;
	} elsif($announce_feed{$curFeed} && -e $file) {

		if (!eval { $rss->parsefile($file); }) {
			&SimBot::debug(1, "rss:  Parse error in $file: $@");
			return;
		}

		if (defined $mostRecentPost{$curFeed}) {
			foreach my $item (@{$rss->{'items'}}) {
				if((defined $item->{'guid'}
				    && $item->{'guid'} eq $mostRecentPost{$curFeed})
				   || $item->{'link'} eq $mostRecentPost{$curFeed}) {
					last;
				} else {
					($link, $title) = &get_link_and_title($item);

					push(@newPosts, "$title  $link");
				}
			}
		}
		if(defined $rss->{'items'}->[0]->{'guid'}) {
			$mostRecentPost{$curFeed} = $rss->{'items'}->[0]->{'guid'};
		} else {
			$mostRecentPost{$curFeed} = $rss->{'items'}->[0]->{'link'};
		}

		if(@newPosts) {
			$title = $rss->{'channel'}->{'title'};
			if($title =~ m/Slashdot Journals/) {
				$title = $rss->{'channel'}->{'description'};
			}
			&SimBot::send_message(CHANNEL,
			  &SimBot::parse_style(&colorize_feed($title)
				            . " has been updated! Here's what's new:"));
			foreach(@newPosts) {
				&SimBot::send_message(CHANNEL, $_);
			}
		}
	}

}

### latest_headlines_stub
# SimBot does not know this is a POE session.  It will call this
# function and we'll post our event.
sub latest_headlines_stub {
    my ($kernel, $nick, $channel, undef, $feed) = @_;
    $kernel->post($session => 'latest_headlines', $nick,
                  $channel, $feed);
}

### latest_headlines
# This outputs the latest headlines for the requested feed to IRC.
sub latest_headlines {
    my ($kernel, $nick, $channel, $feed)
        = @_[ KERNEL, ARG0, ARG1, ARG2 ];
    my ($item, $title, $link);
    my $rss = new XML::RSS;

    &SimBot::debug(3, "rss: Got request from $nick" .
				   (defined $feed ? " for $feed" : "") . "...\n");

    if(defined $feed && defined $feeds{$feed}) {
        my $file = "caches/${feed}.xml";
        if(!-e $file || -M $file > (EXPIRE / 86400)) {
            &SimBot::debug(4, "rss: $feed is old or missing.\n");
            # cache is stale or missing, we need to go fetch it
            # before we announce anything.
            my $request = HTTP::Request->new(GET => $feeds{$feed});
            if(-e $file) {
                my $mtime = (stat($file))[9];
                $request->if_modified_since($mtime);
            }

            $kernel->post( 'ua' => 'request', 'got_response',
                            $request, "$feed!!$nick");
        } else {
            &SimBot::debug(4,
                           "rss: $feed is up to date; Displaying.\n");
            $kernel->post($session => 'announce_top', $feed, $nick,
                          $channel);
        }
    } else {
        &SimBot::debug(4, "rss: No feed matched request.\n");
        my $message = "$nick: "
            . ($feed ? "I have no feed $feed."
                     : "What feed do you want latest posts from?")
            . ' Try one of:';
        foreach(sort keys %feeds) {
            $message .= " $_";
        }
        &SimBot::send_message($channel, $message);
    }
}

### announce_top
# Called when someone requests the top few headlines for a feed, and
# we already have an up to date cache
sub announce_top {
    my ($feed, $nick, $channel) = @_[ ARG0, ARG1, ARG2 ];
    my ($rss, $link, $title, $item);
	my $file = "caches/${feed}.xml";
    if(-e $file) {
		$rss = new XML::RSS;
		if (!eval { $rss->parsefile($file); }) {
			&SimBot::debug(1, "rss:  Parse error in $file: $@");
			&SimBot::send_message($channel, "$nick: I have no idea what's going on with the $feed feed because the file I got didn't make sense to me.  If the feed owner corrects the feed, you should be able to ask me again later.");
			return;
		}

		$title = $rss->{'channel'}->{'title'};
		if($title =~ m/Slashdot Journals/) {
			$title = $rss->{'channel'}->{'description'};
		}
		&SimBot::send_message($channel, &SimBot::parse_style(
			 "$nick: Here are the latest posts to "
			 . &colorize_feed($title) . ':'));
		for(my $i=0;
			$i <= ($#{$rss->{'items'}} < 2 ? $#{$rss->{'items'}} : 2);
			$i++)
		{
			$item = ${$rss->{'items'}}[$i];
			($link, $title) = &get_link_and_title($item);

			&SimBot::send_message($channel, "$title  $link");
		}
	} else {
		&SimBot::send_message($channel, "$nick: $feed is unavailable.  The feed seems to be down and I don't have an old copy to show you.");
	}
}

sub colorize_feed {
    my $feed = $_[0];
    if(defined FEED_TITLE_STYLE) {
        return FEED_TITLE_STYLE . $feed . '%normal%';
    } else {
        return $feed;
    }
}

sub get_link_and_title {
    my $item = $_[0];
    my $link = $item->{'link'};
    my $title = $item->{'title'};

    # Does the link go through the silly Fark redirect?
    # If so, let's remove it.
    if($link =~ s{^http://go\.fark\.com/cgi/fark/go\.pl\?\S*&location=(\S*)$}{$1}) {
        $link =~ s{%3f}{?};
        $link =~ s{%26}{&}g;
    }

    $title = ($item->{'title'} ? $item->{'title'} : "");
    $title = HTML::Entities::decode($title);
    $title = Encode::decode('utf8', $title);
    $title =~ s/\t/  /g;

    return ($link, $title);
}

sub nlp_match {
    my ($kernel, $nick, $channel, $plugin, @params) = @_;

	my $feed;

	foreach (@params) {
		if (m/(\w+)\'s (rss|feed|posts|headlines)/i) { # '
			$feed = $1;
		} elsif (m/(\w+) (\w+)/i) {
			$feed = $2;
		}
	}

	if (defined $feed) {
		$kernel->post($session => 'latest_headlines', $nick, $channel,
		              $feed);
		return 1;
	} else {
		return 0;
	}
}

&SimBot::plugin_register(
    plugin_id   => 'rss',
    plugin_desc => 'Lists the three most recent posts in the requested RSS feed.',
    event_plugin_call     => \&latest_headlines_stub,
    event_plugin_load     => \&messup_rss,
    event_plugin_unload   => \&cleanup_rss,

	event_plugin_nlp_call => \&nlp_match,
	hash_plugin_nlp_verbs =>
						 ["rss", "feed", "posts", "headlines", "news"],
	hash_plugin_nlp_formats =>
						 ["{at} {w}", "{on} {w}", "{for} {w}", "{from} {w}",
						  "{w}\'s rss", "{w}\'s feed", "{w}\'s posts",
						  "{w}\'s headlines"],
	hash_plugin_nlp_questions =>
						 ["what-are", "command","i-want",
						  "i-need", "how-about", "you-must"],
);
