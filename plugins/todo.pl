# SimBot Todo List Plugin
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

package SimBot::plugin::todo;

@todo = (
	 "1) %delete: allow users to delete words used less than x times",
	 "2) %recap: handle more events including channel modes and notices",
	 "3) detect and remove orphaned and dead end words",
	 "4) perform automatic database backups",
	 "--- Increment version to 6.0 beta (then final) here ---",
	 "5) eventually recognize the possibility for joining 2+ channels",
	 "6) allow for media other than IRC to be used (connection plugins)",
	 );

# PRINT_TODO: Prints todo list privately to the user.
sub print_todo {
    my ($kernel, $nick) = @_;
    &SimBot::debug(3, "Received todo command from " . $nick . ".\n");
    if (@todo) {
		foreach(@todo) {
			&SimBot::send_message($nick, $_);
		}
    } else {
		&SimBot::send_message($nick, "Request some features!  My todo list is empty!");
    }
}

# Register Plugin
&SimBot::plugin_register(plugin_id   => "todo",
						 plugin_desc => "Where the hell am I going?",
						 modules     => "",

						 event_plugin_call => \&print_todo,
						 );


