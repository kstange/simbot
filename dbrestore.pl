#!/usr/bin/perl -w

$file = $ARGV[0];
$dbname = $file;
$dbname =~ s/\..*?$//;

open(DBDUMP, $file) || die $!;
dbmopen(%db, $dbname, 0665) || die $!;

while(<DBDUMP>) {
	chomp;
	($key, $value) = split(" => ");
    $db{$key} = $value;
}

dbmclose(%db);
close(DBDUMP);
