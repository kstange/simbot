#!/usr/bin/perl

use DBI;
use warnings;

my $dbh = DBI->connect(
        'dbi:SQLite:dbname=irclog',
        '','', # user, pass aren't useful to SQLite
    ) or die;

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

