#!/usr/bin/perl

# SimBot Statistics Rebuilder
#
# DESCRIPTION:
#   Recreates the statistics tables for SimBot. This should only be needed
#   when new features are added to the sqlite logger's statistics, or
#   when updating the database manually.
#
# COPYRIGHT:
#   Copyright (C) 2005, Pete Pearson
#
#   This program is free software; you can redistribute and/or modify it
#   under the terms of version 2 of the GNU General Public License as
#   published by the Free Software Foundation.
#   
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#   
#   You should have received a copy of the GNU General Public License
#   along with this program; if not, write to the Free Software
#   Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA

use warnings;
use strict;
use DBI;

$|=1; # turn off output buffering on STDOUT so we can output .s occasionally
      # so it looks like we are doing something
      
our $dbh = DBI->connect('dbi:SQLite:dbname=data/irclog','','',
    { RaiseError => 1, AutoCommit => 0 })
    or die 'Could not set up SQLite DB!';
    

print 'Resetting the nickname stats table...';
{
    local $dbh->{RaiseError}; # let's not die in this block
    local $dbh->{PrintError}; # and let's be quiet
    
    $dbh->do('DROP TABLE nickstats');
    
    $dbh->do(<<EOT);
CREATE TABLE nick_hour_counts (
    nick_id INTEGER,
    channel_id INTEGER,
    hour INTEGER,
    count INTEGER
);
EOT
}

print " Done.\n";

# Now we loop through every line in the log.

my $query = $dbh->prepare('SELECT time, channel_id, source_nick_id FROM chatlog');
my $update_query = $dbh->prepare(
    'UPDATE nick_hour_counts'
    . ' SET count = count + 1'
    . ' WHERE nick_id = ?'
    . ' AND channel_id = ?'
    . ' AND hour = ?');

my $insert_query = $dbh->prepare(
    'INSERT INTO nick_hour_counts'
    . ' (nick_id, channel_id, hour, count)'
    . ' VALUES (?, ?, ?, 1)');
$query->execute();

print "Calculating users' hourly line counts";
my $row_number = 0;

while(my ($time, $channel_id, $nick_id) = $query->fetchrow_array) {
    my $hour = (gmtime($time))[2];
    
    unless(int $update_query->execute($nick_id, $channel_id, $hour)) {
        $insert_query->execute($nick_id, $channel_id, $hour);
    }
    
    if(++$row_number % 800 == 0) {
        print '.';
    }
}
print " Done\nCommitting...";

$dbh->commit;

print " Done\n";
