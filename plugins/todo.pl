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

use strict;
use warnings;

our %vers = (
	     "6.0 Beta"   =>  1,
	     "6.0 Final"  =>  1,
	     "General"    =>  1,
	     );

# PRINT_TODO: Prints todo list privately to the user.
sub print_todo {
    my ($kernel, $nick) = @_;
    &SimBot::debug(3, "todo: Received request from " . $nick . ".\n");

    if(open(TODO, "TODO")) {
	my $version = "";
	my $todo = "";
	my $prev = "";
	foreach my $line (<TODO>) {
	    next if !defined $line;
	    chomp $line;
	    if ($line eq "======================") {
		if ($prev =~ /^Targets for (.*)/) {
		    $version = $1;
		    if (defined $vers{$version}) {
			$todo .= "For Version $version:\n";
		    }
		} else {
		    $version = $prev;
		    if (defined $vers{$version}) {
			$todo .= "$version Items:\n";
		    }
		}
	    } elsif (defined $vers{$version} && $line =~ /^- (.*)/) {
		$todo .= "- $1\n";
	    }
	    $prev = $line;
	}
	
	if ($todo ne "") {
	    chomp $todo;
	    &SimBot::send_pieces($nick, undef, $todo);
	}
    }
}

# Register Plugin
&SimBot::plugin_register(plugin_id   => "todo",
			 plugin_desc => "The ever changing development todo list",
			 event_plugin_call => \&print_todo,
			 );


