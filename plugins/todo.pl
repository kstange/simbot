# SimBot Todo List Plugin
#
# Copyright (C) 2003, Kevin M Stange <kevin@simguy.net>
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

package SimBot::plugin::todo;

@todo = (
	 "1) %delete: allow users to delete words used less than x times",
	 "2) %recap: allow users to request scrollback of up to x lines",
	 "3) create a means for automatic dead words cleanup",
	 "4) add detection for the return of X and log back in",
	 "5) automatically perform regular db backups",
	 "--- Finish above this line and we'll increment to 6.0 final ---",
	 "6) maybe: grab contextual hinting",
	 "7) maybe: do some runaway loop detection",
	 "8) pray for IRC module to start supporting QUIT properly",
	 );

# PRINT_TODO: Prints todo list privately to the user.
sub print_todo {
    my ($kernel, $nick) = @_;
    SimBot::debug(3, "Received todo command from " . $nick . ".\n");
    if (@todo) {
	foreach(@todo) {
	    $kernel->post(bot => privmsg => $nick, $_);
	}
    } else {
	$kernel->post(bot => privmsg => $nick, "Request some features!  My todo list is empty!");
    }
}

# Register Plugin
SimBot::plugin_register(plugin_id   => "todo",
			plugin_desc => "Where the hell am I going?",
			modules     => "",

			event_plugin_call => "print_todo",
			);


