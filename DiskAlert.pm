#!/usr/bin/perl -w
package DiskAlert;
sub MY () {__PACKAGE__}
use strict;
use warnings FATAL => qw(all);

{
  package DiskAlert::Object; sub MY () {__PACKAGE__}
  sub new {
    my MY $self = fields::new(shift);
    $self->configure(@_) if @_;
    $self;
  }
  sub configure {
    my MY $self = shift;
    my @task;
    while (my ($name, $value) = splice @_, 0, 2) {
      if (my $task = $self->can("configure_$name")) {
	push @task, [$task, $value];
      } else {
	$self->{"cf_$name"} = $value;
      }
    }
    $_->[0]->($self, $_->[1]) for @task;
    $self;
  }
}
{
  sub Watch () {'DiskAlert::Watch'}
  package DiskAlert::Watch; sub MY () {__PACKAGE__}
  use base qw(DiskAlert::Object);
  use fields qw(cf_mnt cf_min cf_decr1);

  our %UNIT = (G => 1024*1024, M => 1024, K => 1);
  sub unit {
    my ($arg) = @_;
    $arg =~ s{^([\d\.]+)([GMK])$}{$1 * $UNIT{$2}}e;
    $arg;
  }
  # XXX: 生成したい
  sub configure_min {
    my MY $self = shift; $self->{cf_min} = unit(shift);
  }
  sub configure_decr1 {
    my MY $self = shift; $self->{cf_decr1} = unit(shift);
  }
}
{
  sub Log () {'DiskAlert::Log'}
  package DiskAlert::Log; sub MY () {__PACKAGE__}
  use base qw(DiskAlert::Object);
  use fields qw(cf_mnt cf_rowid cf_at cf_datetime cf_total cf_used cf_avail);
}

use base qw(DiskAlert::Object);
use fields qw(DBH mntids watchlist watchdict
	      cf_db cf_verbose cf_time cf_ro cf_limit
	      in_transaction);

use DBI;

sub DBH {
  my MY $self = shift;
  unless ($self->{DBH}) {
    my $dbfn = $self->{cf_db} or die "$0: db is not specified\n";
    my $first = not -e $dbfn;
    $self->{DBH} = my $dbh = DBI->connect
      ("dbi:SQLite:dbname=$dbfn", undef, undef
       , {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    chmod 0664, $dbfn or die "Can't chmod $dbfn\n" if $first;
    $self->cmd_setup if $first;
  }
  $self->{DBH};
}

sub open_df {
  my MY $self = shift;
  open my $fh, '-|', 'df', '-P' or die $!;
  $self->{cf_time} //= time;
  scalar <$fh>; # ヘッダ読み捨て
  $fh;
}

sub cmd_setup {
  my MY $self = shift;
  my $dbh = $self->DBH;
  foreach my $sql ($self->schema) {
    $dbh->do($sql);
  }
}

sub mntid {
  my MY $self = shift;
  $self->{mntids} ||= do {
    my $res = $self->DBH->selectcol_arrayref(<<END, {Columns => [1, 2]});
select mnt, mntid from disk
END
    my %hash = @$res;
    \%hash;
  };
  return $self->{mntids} unless @_;
  my ($mnt, $dev) = @_;
  # XXX:
  $self->{mntids}{$mnt} ||= do {
    $self->DBH->do(<<END, undef, $mnt, $dev);
insert into disk(mnt, dev) values(?, ?)
END

    $self->DBH->func('last_insert_rowid');
  };
}

sub cmd_list {
  (my MY $self, my @mnt) = @_;
  my %target; $target{$_} = 1 for @mnt;
  $self->list(undef, @mnt ? \%target : undef);
}

sub load_watchlist {
  my MY $self = shift;
  $self->{watchlist} ||= \ my @watch;
  $self->{watchdict} ||= \ my %watch;
  while (@_ and $_[0] =~ m{^/}) {
    my $mnt = shift;
    my @opt;
    for (; @_ and $_[0] =~ /^(\w+)=(.*)/s; shift) {
      push @opt, $1, $2;
    }
    push @watch, $watch{$mnt} = $self->Watch->new(mnt => $mnt, @opt);
  }
}

sub cmd_load {
  my MY $self = shift;
  $self->load_watchlist(@_);
  return if $self->{cf_ro}; # readonly
  with_dbh {$self} $self->DBH, sub {
    list {$self} sub {
      my ($dev, $total, $used, $avail, $fillratio, $mnt) = @_;
      my $mntid = $self->mntid($mnt, $dev);
      $self->log_insert($mntid, $self->{cf_time}
			, $total, $used, $avail);
    }, $self->{watchdict};
  };
}

sub cmd_watch {
  my MY $self = shift;
  $self->cmd_load(@_);
  with_dbh {$self} $self->DBH, sub {
    foreach my Watch $watch (@{$self->{watchlist}}) {
      my @last2 = (my Log $prev, my Log $now)
	= $self->log_list_as(hash => $watch->{cf_mnt}, 2);
      if ($watch->{cf_min} and @last2 == 2
	  and $now->{cf_avail} < $watch->{cf_min}) {
	# use Data::Dumper; print Dumper($now), "\n";
	$self->alertfmt("%s capacity reduced to %dK (min=%dK) diff=%dK"
			, $watch->{cf_mnt}, $now->{cf_avail}
			, $watch->{cf_min}
			, $prev->{cf_avail} - $now->{cf_avail}
		       );
      }
      if ($watch->{cf_decr1} and @last2 == 2
	  and (my $diff = $prev->{cf_avail} - $now->{cf_avail})
	  >= $watch->{cf_decr1}) {
	$self->alertfmt("%s reduced %dK at one period. now avail=%dK"
			, $watch->{cf_mnt}, $diff, $now->{cf_avail}
		       );
      }
    }
  };
}

sub cmd_list_disks {
  my MY $self = shift;
  my $hash = $self->mntid;
  print join("\n", sort keys %$hash), "\n";
}

sub cmd_list_growth {
  (my MY $self, my $mnt) = @_;
  print join("\t", qw(at datetime used avail growth)), "\n";

  with_dbh {$self} $self->DBH, sub {
    my Log $prev;
    $self->log_list_as
      (hash => $mnt, $self->{cf_limit}, sub {
	 (my Log $log) = @_;
	 print join("\t", $log->{cf_at}, $log->{cf_datetime}
		    , $log->{cf_used}, $log->{cf_avail}
		    , $prev ? $log->{cf_used} - $prev->{cf_used} : 0
		   ), "\n";
	 $prev = $log;
       });
  };
}

sub alertfmt {
  (my MY $self, my $fmt) = splice @_, 0, 2;
  printf $fmt, @_; print "\n";
}

sub log_list_as {
  (my MY $self, my ($mode, $mnt, $limit, $sub)) = @_;
  my $dbh = $self->DBH;
  my $sth = $dbh->prepare(<<END . ($limit ? sprintf('limit %d', $limit) : ''));
select rowid, at, datetime(at, 'unixepoch', 'localtime') as datetime
, total, used, avail from log
where mntid = (select mntid from disk where mnt = ?)
order by rowid
END

  $sth->execute($mnt) or return;

  my @res;
  if ($mode eq 'hash') {
    while (my $row = $sth->fetchrow_hashref) {
      my $log = $self->Log->new(mnt => $mnt, %$row);
      if ($sub) {
	$sub->($log);
      } else {
	push @res, $log;
      }
    }
  } elsif ($mode eq 'array') {
    push @res, [@{$sth->{NAME}}];
    while (my @row = $sth->fetchrow_array) {
      push @res, \@row;
    }
  }
  @res;
}

sub log_insert {
  (my MY $self, my ($mntid, $at, $total, $used, $avail)) = @_;
  print "inserting ($mntid, $at, $total, $used, $avail)\n"
    if $self->{cf_verbose};
  $self->DBH->do(<<END, undef, ($mntid, $at, $total, $used, $avail));
insert into log(mntid, at, total, used, avail)
values (?, ?, ?, ?, ?)
END

  $self->DBH->func('last_insert_rowid');
}

#========================================-

sub schema {
  shift;
  (q{create table disk
(mntid integer primary key
, mnt text
, dev text
)}
   , q{create table log
(mntid integer
, at datetime
, total integer, used integer, avail integer
)}
  );
}

sub list {
  (my MY $self, my ($sub, $filter)) = @_;
  my $fh = $self->open_df;
  while (defined (my $line = <$fh>)) {
    chomp $line;
    my @all = my ($path, $total, $used, $avail, $fillratio, $mnt)
      = split " ", $line;
    next if $mnt =~ m{^/dev/};
    next if $filter and keys %$filter and not $filter->{$mnt};
    if ($sub) {
      $sub->(@all);
    } else {
      print join("\t", @all), "\n";
    }
  }
}

sub with_dbh {
  (my MY $self, my ($dbh, $sub)) = @_;
  if ($self->{in_transaction}) {
    $sub->();
  } else {
    $dbh->do($self->{cf_ro} ? "begin" : "begin immediate");
    $sub->();
    $dbh->do("commit");
  }
}

#========================================-

sub parse_opts {
  my ($pack, $aref, $res) = @_;
  $res ||= [];
  while (@$aref and $aref->[0] =~ /^--(?:(\w+)(?:=(.*))?)?/) {
    shift @$aref;
    last unless defined $1;
    push @$res, $1, $2 // 1;
  }
  wantarray ? @$res : $res;
}

unless (caller) {
  my MY $self = MY->new(MY->parse_opts(\@ARGV));
  unless (@ARGV) {
    die "$0 [--db=file] cmd...\n";
  }
  my $cmd = shift @ARGV;
  if (my $sub = $self->can("cmd_$cmd")) {
    $sub->($self, @ARGV);
  } elsif ($sub = $self->can($cmd)) {
    my @res = $sub->($self, @ARGV);
    print join("\n", map {ref $_ ? join("\t", @$_) : $_} @res), "\n" if @res;
  } else {
    die "$0: No such command $cmd\n";
  }
}

1;
