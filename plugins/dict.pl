# SimBot Dictionary Plugin
#
# Copyright (C) 2003-04, Kevin M Stange <kevin@simguy.net>
#
# This program is free software; you can redistribute it and/or modify
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

package SimBot::plugin::define;

use strict;
use warnings;

# Support for the Dict protocol is found here:
use Net::Dict;

# LOOK UP: Prints a defintion to the channel.
sub look_up {
    my ($kernel, $nick, $channel, $command, $term, $dictionary) = @_;
	$dictionary = 'jargon' if (!defined $dictionary);

	my $dict = Net::Dict->new("pan.alephnull.com",
							  Client => SimBot::PROJECT . " " . SimBot::VERSION,
							  );

	my %dbs = $dict->dbs();

	if (!defined $term) {
		&SimBot::send_message($channel, "$nick: Please specify which word you want defined. If you wish, you can specify one of " . join(", ", keys(%dbs)) . " after the word to indicate which dictionary to use. Otherwise, the Jargon File will be searched.");
		return;
	}

	my $found = 0;
	foreach (keys(%dbs)) {
		if ($_ eq $dictionary) {
			$found = 1;
			last;
		}
	}

	if($found) {
		&SimBot::debug(3, "Received define command from " . $nick . ".\n");

		my $def = $dict->define($term, ($dictionary));
		if (@{$def} != 0) {
			my $definition = ${${$def}[0]}[1];
			$definition =~ s/\s+/ /g;

			if (length($definition) > 400 && $command !~ /_private$/) {
				&SimBot::send_message($channel, "$nick: I found a definition in the $dbs{$dictionary}, but it is " . length($definition) . " bytes long. Type \"" . $command . "_private $term $dictionary\" to see it privately.");
			} elsif ($command =~ /_private$/) {
				&SimBot::send_pieces($nick, undef, "From the $dbs{$dictionary}: $definition");
			} else {
				&SimBot::send_message($channel, "$nick: From the $dbs{$dictionary}: $definition");
			}
		} else {
			&SimBot::send_message($channel, "$nick: I could not find a definition for $term in the $dbs{$dictionary}.");
		}
	} else {
		&SimBot::send_message($channel, "$nick: There is no such dictionary available. Try one of " . join(", ", keys(%dbs)) . ".");
	}
}

# Register Plugin
&SimBot::plugin_register(plugin_id   => "define",
						 plugin_desc => "Defines the term. Defaults to Jargon.  Follow a term by a dictionary name to search an alternate dictionary.",

						 event_plugin_call => \&look_up,
						 );

&SimBot::plugin_register(plugin_id   => "define_private",
						 plugin_desc => "Defines the term privately to you.",

						 event_plugin_call => \&look_up,
						 );
