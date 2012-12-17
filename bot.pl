#!/usr/bin/env perl
use strict;
use warnings;

use AnyEvent;
use AnyEvent::IRC::Client;
use Data::Dumper;
use DBI;
use Getopt::Long;
use LWP::UserAgent;

$| = 1;
my %opt = (
    channel => '#burato',
    nick    => "logger1",
    port    => 6667,
    server  => 'irc.freenode.net',
    verbose => undef,
    dbname  => 'irc_log.db',
);

GetOptions(\%opt,'channel=s','nick=s', 'port', 'server', 'verbose|v', 'dbname');
my $message = shift || "I started logging your asses at @{[ scalar localtime ]}";

init_db();

if ($opt{verbose}) {
    warn "message is: '$message'";
    warn Data::Dumper->Dump([\%opt], [qw(*opt)]);
}

my $c = AnyEvent->condvar;
my $con = AnyEvent::IRC::Client->new;

$con->reg_cb(
    join => sub {
        my ($con, $nick, $channel, $is_myself) = @_;

        if ($is_myself && $channel eq $opt{channel}) {
            $con->send_chan($channel, PRIVMSG => $channel, $message);
        }
    },
    publicmsg => sub {
        my ($con, $nick, $ircmsg) = @_;

        my $msg = $ircmsg->{'params'}[1];
        if ($msg =~ /^showlog\s*(\d*)$/) {
          my $count = $1 || 10;
          showlog($count);
        }
        else {
            my $db = connect_db();
            my $sql = 'insert into messages (nick, message) values (?, ?)';
            my $sth = $db->prepare($sql) or die $db->errstr;
            my ($nick) = $ircmsg->{'prefix'} =~ /^(.*)!/;
            $sth->execute($nick, $msg);
        }
    },
    kick => sub {
        my ($con, $kicked, $channel, $is_myself, $msg, $kicker) = @_;
        if ($kicked eq $opt{nick}) {
            $con->send_srv(JOIN => $channel);
            $con->send_chan($channel, PRIVMSG => ($channel, "Go kick yourself, $kicker!!"));
            warn $msg if $is_myself;
        }
    }
);

$con->connect($opt{server}, $opt{port}, { nick => $opt{nick} });
$con->send_srv(JOIN => $opt{channel});

$c->wait;
$con->disconnect;

sub showlog {
    my $count = shift;
    my $db = connect_db();
    my $sql = << "SQL";
select id, nick, message, datetime(time, 'localtime') as time
from messages order by id desc limit $count
SQL
    my $sth = $db->prepare($sql) or die $db->errstr;
    $sth->execute or die $sth->errstr;
    my $msgs = $sth->fetchall_hashref('id');
    my $log;
    $log .= join '', '[', $msgs->{$_}{'time'}, '] ',
    $msgs->{$_}{'nick'}, ": ", $msgs->{$_}{'message'}, "\n"
    for sort {$a <=> $b} keys $msgs;
    my $ua = LWP::UserAgent->new;
    my $res = $ua->post('http://sprunge.us', ['sprunge' => $log])->content;
    $res =~ s/\n/?irc/;
    $con->send_chan($opt{'channel'}, PRIVMSG => ($opt{'channel'}, "Last $count messages:$res"));
}

sub connect_db {
    my $dbfile = $opt{'dbname'};
    my $dbh    = DBI->connect("dbi:SQLite:dbname=$dbfile") or
        die $DBI::errstr;
    return $dbh;
}

sub init_db {
    my $db     = connect_db();
    my $schema = do {local $/ = <DATA>};
    $db->do($schema) or die $db->errstr;
}

__DATA__
create table if not exists messages (
  id integer primary key autoincrement,
  nick string not null,
  message string not null,
  time timestamp default current_timestamp
);
