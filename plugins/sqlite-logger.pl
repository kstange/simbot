###
#  SimBot sqlite Logger Plugin
#
# DESCRIPTION:
#   Logs chat SimBot sees to a SQLite log. This could be used to 
#   generate channel statistics, a more intelligent seen plugin, and
#   more.
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
#   *
#


package SimBot::plugin::sqlite::logger;

use warnings;
use strict;

use vars qw( $dbh $insert_query $get_nickchan_id_query $get_nickchan_name_query $add_nickchan_id_query );

use DBI;

use constant MONTHS => ('Jan','Feb','Mar','Apr','May','Jun','Jul','Aug',
    'Sep','Oct','Nov','Dec');
    
use constant WEB_IRCLOG_PL => 'http://128.153.223.58/cgi-bin/irclog.pl';
use constant USE_WEB_IRCLOG_PL => 0;

sub messup_sqlite_logger {
    $dbh = DBI->connect(
        'dbi:SQLite:dbname=irclog',
        '','', # user, pass aren't useful to SQLite
        { RaiseError => 1, AutoCommit => 0 }
    ) or die;
    &SimBot::debug(3, 'sqlite: Using SQLite version '
        . $dbh->{'sqlite_version'} . "\n");
        
    # let's create our table. If this fails, we don't care.
    {
        local $dbh->{RaiseError}; # let's not die in this block
        local $dbh->{PrintError}; # and let's be quiet
        $dbh->do(<<EOT);
CREATE TABLE chatlog (
    id INTEGER PRIMARY KEY,
    time INTEGER,
    channel_id INTEGER,
    source_nick_id INTEGER,
    event STRING,
    target_nick_id INTEGER,
    content STRING);
EOT

        $dbh->do(<<EOT);
CREATE TABLE names (
    id INTEGER PRIMARY KEY,
    name STRING,
    context STRING);
EOT
        $dbh->commit;
    }
    
    # let's prepare the insert query now, it'll be used a lot so
    # keeping it ready is a good idea
    $insert_query = $dbh->prepare(
        'INSERT INTO chatlog '
        . ' (time, channel_id, source_nick_id, target_nick_id, event, content) '
        . ' VALUES (?, ?, ?, ?, ?, ?)'
    );
    
    # and the query to fetch a nick ID
    $get_nickchan_id_query = $dbh->prepare(
        'SELECT id FROM names'
        . ' WHERE lower(name) = lower(?)'
        . ' LIMIT 1'
    );
    
    # and the query to fetch a nick name from ID
    $get_nickchan_name_query = $dbh->prepare(
        'SELECT name FROM names WHERE id = ? LIMIT 1' );
    
    # and the query to add one
    $add_nickchan_id_query = $dbh->prepare(
        'INSERT INTO names (name) VALUES (?)'
    );
}

sub cleanup_sqlite_logger {
    $dbh->disconnect;
}

# get_nickchan_id is called whenever a nickname ID or channel ID is
# needed.
# name will be the name of the chnanel or nickname
sub get_nickchan_id {
    my ($name, $add_unknown) = @_;
    my $id;
    
    $get_nickchan_id_query->execute($name) or die;
    if(($id) = $get_nickchan_id_query->fetchrow_array()) {
        $get_nickchan_id_query->finish;
    } else {
        $get_nickchan_id_query->finish;
        if($add_unknown) {
            $add_nickchan_id_query->execute($name);
            $id = $dbh->last_insert_id(undef,undef,'names',undef);

            $add_nickchan_id_query->finish;
        } else {
            return undef;
        }
    }
    return $id;
}

# get_nickchan_name reverses get_nickchan_id
sub get_nickchan_name {
    my ($id) = @_;
    my $name;
    
    $get_nickchan_name_query->execute($id) or die;
    ($name) = $get_nickchan_name_query->fetchrow_array();
    $get_nickchan_name_query->finish;
    return $name;
}

sub log_nick_change {
    my (undef, undef, $nick, $newnick) = @_;
    my $channel_id = &get_nickchan_id(
        &SimBot::option('network', 'channel'), 0
    );
    
    my $source_nick_id = &get_nickchan_id($nick, 1);
    my $target_nick_id = &get_nickchan_id($newnick, 1);
    
    $insert_query->execute(time, $channel_id, $source_nick_id,
        $target_nick_id, 'NICK', undef);
    $insert_query->finish;
    $dbh->commit;
}

sub set_seen {
    # lots of undefs here, and we mean 'em all. Shut up about it.
    no warnings qw( uninitialized );
    
    my($kernel, $nick, $channel, $doing, $content, $target) = @_;
#    SimBot::debug(4, "sqlite-logger: Logging $nick ($doing $content)\n");
    my $time = time;

    # First, we need to identify things
#    my $channel_id = &get_nickchan_id('channels', $channel);
    my $channel_id = &get_nickchan_id(
        &SimBot::option('network', 'channel'),
        1
    );
    my $source_nick_id = &get_nickchan_id($nick, 1);
    my $target_nick_id;
    
    if($doing eq 'KICKED') {
        # IRC kicks are foo got kicked by bar
        # let's store it so that foo is the target.
        $target_nick_id = $source_nick_id;
        $source_nick_id = &get_nickchan_id($target, 1);
    } elsif($doing eq 'MODE') {
        # $target will be the arguments for the mode change options
        # let's add them to the content
        $content .= " $target";
    } elsif($doing eq 'ACTION') {
        (undef, $content) = split(/ /, $content, 2);
    }
    
    $insert_query->execute(time, $channel_id, $source_nick_id, $target_nick_id, $doing, $content);
    $insert_query->finish;
    $dbh->commit;
}

sub access_log {
    my ($kernel, $nick, $channel, $self, $query, @args) = @_;
    
    my $nick_id = &get_nickchan_id($nick);
    
    if($query =~ m/^recap$/) {
        # let's autorecap!
        # first, we need to find when the person asking for the recap
        # left.
        
        my $start_query = $dbh->prepare(
            'SELECT id FROM chatlog'
            . ' WHERE channel_id = ?'
            . ' AND source_nick_id = ?'
            . ' AND (event = \'PARTED\''
            . ' OR event = \'QUIT\''
            . ' OR event = \'KICKED\')'
            . ' ORDER BY time DESC'
            . ' LIMIT 1'
        );
        
        my $end_query = $dbh->prepare(
            'SELECT id FROM chatlog'
            . ' WHERE channel_id = ?'
            . ' AND source_nick_id = ?'
            . ' AND event = \'JOINED\''
            . ' ORDER BY time DESC'
            . ' LIMIT 1'
        );
        
        my $log_query = $dbh->prepare(
            'SELECT time, source_nick_id, event,'
            . ' target_nick_id, content'
            . ' FROM chatlog'
            . ' WHERE channel_id = ?'
            . ' AND id >= ?'
            . ' AND id <= ?'
        );
        
        my $channel_id = &get_nickchan_id(
            &SimBot::option('network', 'channel')
        );
        $start_query->execute(
            $channel_id,
            $nick_id
        );
        
        my $start_row;
        unless(($start_row) = $start_query->fetchrow_array) {
            $start_query->finish;
            &SimBot::send_message($channel,
                "$nick: Sorry, I didn't see you leave!"
            );
            return;
        }
        $start_query->finish;
        
        $end_query->execute(
            $channel_id,
            $nick_id
        );
        my $end_row;
        unless(($end_row) = $end_query->fetchrow_array) {
            $end_query->finish;
            &SimBot::send_message($channel,
                "$nick: Sorry, I didn't see you come back!"
            );
            return;
        }
        $end_query->finish;
        
        # ok, so now we have the range to fetch...
        # let's get it!
        $log_query->execute($channel_id, $start_row, $end_row);
        if($log_query->rows == 2) {
            $log_query->finish;
            # the log only shows the person leaving and joining
            &SimBot::send_message($channel,
                "$nick: Nothing happened while you were gone."
            );
            return;
        }
        
        if(USE_WEB_IRCLOG_PL) {
            $log_query->finish;
            &SimBot::send_message($channel,
                "$nick: Your recap: "
                . WEB_IRCLOG_PL
                . "?recap=${nick_id}&chanid=${channel_id}"
            );
            return;
        }
        my @msg;
        my $row;
        while($row = $log_query->fetchrow_hashref) {
            push(@msg, &row_hashref_to_text($row));
        }
        $log_query->finish;
        &SimBot::send_pieces_with_notice($nick, undef,
            join("\n", @msg));
    } elsif($query =~ m/seen/) {
        my ($seen_nick, $seen_nick_id, $seen_row);
        my @events;
        
        if($args[0] eq 'before' && $args[1] eq 'that') {
            my $context = &get_nick_context($nick_id);
            
            if($context =~ m/seen=(\d+)/) {
                $seen_nick_id = $1;
            } else {
                &SimBot::send_message($channel,
                    "$nick: I don't seem to remember what 'that' is.");
                return;
            }
            if($context =~ m/seen-row=(\d+)/) {
                $seen_row = $1;
            } else {
                die 'This shouldn\'t happen!';
            }
            if($context =~ m/seen-event=(\S+)/) {
                @events = split(/,/, $1);
            }
            
        } else {
            $seen_nick = shift(@args);
            &SimBot::debug(3, "sqlite-logger: Seen request by $nick for $seen_nick\n");
            unless($seen_nick_id = &get_nickchan_id($seen_nick)) {
                &SimBot::send_message($channel,
                    "$nick: I do not know of a $seen_nick");
                return;
            }
        
            while(my $cur_arg = shift(@args)) {
                if($cur_arg =~ /(say|join|part|quit|nick|kick|notice|action|topic)/i) {
                    my $cur_event = $1;
                    if($cur_event =~ /^(join|part|quit|kick)$/i) 
                        { $cur_event .= 'ed'; }
                        
                    push(@events, uc($cur_event));
                } elsif($cur_arg =~ m/before/) {
                    my $time = shift(@args);
                    
                }
            }
        }

        my $seen_query;
        my $query_str = 
            'SELECT id, time, source_nick_id, event,'
            . ' target_nick_id, content'
            . ' FROM chatlog'
            . ' WHERE (source_nick_id = ?'
            . ' OR target_nick_id = ?)';
        if(defined $seen_row) {
            $query_str .= " AND id < $seen_row"; 
        }
        $query_str .= ' AND channel_id = ?';
        if(@events) {
            $query_str .= 
                " AND (event = '" . join("' OR event = '", @events) . "')";
        }
        $query_str .= ' ORDER BY time DESC'
            . ' LIMIT 1';
            
        unless($seen_query = $dbh->prepare($query_str)) {
            &SimBot::send_message($channel,
                "$nick: Sorry, but something went wrong accessing the log.");
            return;
        }
        $seen_query->execute($seen_nick_id, $seen_nick_id, &get_nickchan_id(&SimBot::option('network', 'channel')));
        
        my $row;
        if($row = $seen_query->fetchrow_hashref) {
            $seen_query->finish;
            &SimBot::send_message($channel,
                "$nick: " . &row_hashref_to_text($row));
        } else {
            $seen_query->finish;
            &SimBot::send_message($channel,
                "$nick: Nothing matched your query.");
            return;
        }
        
        # update context so 'before that' works
        &update_nick_context($nick_id, 'seen-row', $row->{'id'});
        &update_nick_context($nick_id, 'seen', $seen_nick_id);
        &update_nick_context($nick_id, 'seen-event',
            join(',', @events));
    } else {
        &SimBot::send_message($channel, "$nick: Sorry, I do not understand that.");
    }
}

sub row_hashref_to_text {
    my ($row) = @_;
    
    my (undef, undef, undef, $cur_day, $cur_month, $cur_yr) = localtime; 
    $cur_month += 1; # localtime gives us 0..11, we want 1..12
    $cur_yr += 1900; # localtime gives us number of years since 1900
    
    my (undef, $min, $hr, $day, $month, $yr) = localtime($row->{'time'});
    $month += 1;
    $yr += 1900;
    
    my $msg = '[';
    
    if($cur_day != $day || $cur_month != $month || $cur_yr != $yr) {
        $msg .= (MONTHS)[$month-1] . " $day ";
    }
    
    if($cur_yr != $yr) { $msg .= "$yr "; }
    
    $msg .= "$hr:$min] ";
    
    if($row->{'event'} eq 'SAY') {
        $msg .= '<' . &get_nickchan_name($row->{'source_nick_id'})
        . '> ' . $row->{'content'};
    } elsif($row->{'event'} eq 'NOTICE') {
        $msg .= '-' . &get_nickchan_name($row->{'source_nick_id'})
        . '- ' . $row->{'content'};
    } elsif($row->{'event'} eq 'ACTION') {
        $msg .= '* ' . $row->{'content'};
    } elsif($row->{'event'} eq 'JOINED') {
        $msg .= '* ' . &get_nickchan_name($row->{'source_nick_id'}) 
            . ' joined.';
    } elsif($row->{'event'} eq 'PARTED') {
        $msg .= '* ' . &get_nickchan_name($row->{'source_nick_id'})
            . ' left (' . $row->{'content'} . ')';
    } elsif($row->{'event'} eq 'QUIT') {
        $msg .= '* ' . &get_nickchan_name($row->{'source_nick_id'})
            . ' quit (' . $row->{'content'} . ')';
    } elsif($row->{'event'} eq 'TOPIC') {
        $msg .= '* ' . &get_nickchan_name($row->{'source_nick_id'})
            . ' changed the topic to: ' . $row->{'content'};
    } elsif($row->{'event'} eq 'MODE') {
        $msg .= '* ' . &get_nickchan_name($row->{'source_nick_id'})
            . ' set ' . $row->{'content'};
    } elsif($row->{'event'} eq 'KICKED') {
        $msg .= '* ' . &get_nickchan_name($row->{'target_nick_id'})
            . ' was kicked by '
            . &get_nickchan_name($row->{'source_nick_id'})
            . ' (' . $row->{'content'} . ')';
    } elsif($row->{'event'} eq 'NICK') {
        $msg .= '* ' . &get_nickchan_name($row->{'source_nick_id'})
            . ' is now known as '
            . &get_nickchan_name($row->{'target_nick_id'});
            
    } else {    # Oh, great, we forgot one.
        $msg .= 'UNKNOWN EVENT ' . $row->{'event'} . ':';
        if(defined $row->{'source_nick_id'})
            { $msg .= ' source:' . &get_nickchan_name($row->{'source_nick_id'}); }
        if(defined $row->{'target_nick_id'})
            { $msg .= ' target:' . &get_nickchan_name($row->{'target_nick_id'}); }
        if(defined $row->{'content'})
            { $msg .= ' content:' . $row->{'content'}; }
    }
    return $msg;
}

sub get_nick_context {
    my ($nick_id) = @_;
    
    my $query = $dbh->prepare(
        'SELECT context FROM names WHERE id = ?'
    );
    $query->execute($nick_id);
    my ($context) = $query->fetchrow_array;
    return $context;
}

sub update_nick_context {
    my ($nick_id, $key, $value) = @_;
    
    my $context = &get_nick_context($nick_id);
    
    if(!defined $value || $value eq  '') {
        unless($context =~ s/${key}=\S+//) {
            # we're trying to unset the value, but it wasn't set
            # no need to commit to the database
            return;
        }
    } elsif($context !~ s/${key}=\S+/${key}=${value}/) {
        $context .= " ${key}=${value}";
    }
    
    my $query = $dbh->prepare(
        'UPDATE names SET context = ? WHERE id = ?'
    );
    $query->execute($context, $nick_id);
}

&SimBot::plugin_register(
    plugin_id               => 'log',
    event_plugin_call       => \&access_log,
    event_plugin_load       => \&messup_sqlite_logger,
    event_plugin_unload     => \&cleanup_sqlite_logger,
    event_channel_kick      => \&set_seen,
    event_channel_message       => \&set_seen,
    event_channel_message_out   => \&set_seen,
    event_channel_action        => \&set_seen,
    event_channel_action_out    => \&set_seen,
    event_channel_notice        => \&set_seen,
    event_channel_notice_out    => \&set_seen,
    event_channel_topic     => \&set_seen,
    event_channel_join      => \&set_seen,
    event_channel_part      => \&set_seen,
    event_channel_mejoin    => \&set_seen,
    event_channel_quit      => \&set_seen,
    event_channel_mode      => \&set_seen,
    event_server_nick       => \&log_nick_change,
#    query_word_score        => \&score_word,

);

