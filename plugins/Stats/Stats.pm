# This code is a part of Slash, and is released under the GPL.
# Copyright 1997-2002 by Open Source Development Network. See README
# and COPYING for more information, or see http://slashcode.com/.
# $Id$

package Slash::Stats;

use strict;
use DBIx::Password;
use Slash;
use Slash::Utility;
use Slash::DB::Utility;

use vars qw($VERSION);
use base 'Slash::DB::Utility';
use base 'Slash::DB::MySQL';

($VERSION) = ' $Revision$ ' =~ /\$Revision:\s+([^\s]+)/;

# On a side note, I am not sure if I liked the way I named the methods either.
# -Brian
sub new {
	my($class, $user) = @_;
	my $self = {};

	my $slashdb = getCurrentDB();
	my $plugins = $slashdb->getDescriptions('plugins');
	return unless $plugins->{'Stats'};

	bless($self, $class);
	$self->{virtual_user} = $user;
	$self->sqlConnect;

	return $self;
}

########################################################
sub createStatDaily {
	my($self, $day, $name, $value, $options) = @_;
	$value = 0 unless $value;
	$options ||= {};

	my $insert = {
		'day'	=> $day,
		'name'	=> $name,
		'value'	=> $value,
	};

	$insert->{section} = $options->{section} if $options->{section};
	$insert->{section} ||= 'all';

	$self->sqlInsert('stats_daily', $insert, { ignore => 1 });
}

########################################################
sub updateStatDaily {
	my($self, $day, $name, $update_clause, $options) = @_;

	my $where = "day = " . $self->sqlQuote($day);
	$where .= " AND name = " . $self->sqlQuote($name);
	my $section = $options->{section} || 'all';
	$where .= " AND section = " . $self->sqlQuote($section);

	return $self->sqlUpdate('stats_daily', {
		-value =>	$update_clause,
	}, $where);
}

########################################################
sub getPointsInPool {
	my($self) = @_;
	return $self->sqlSelect('SUM(points)', 'users_comments');
}

########################################################
sub getAdminsClearpass {
	my($self) = @_;
	return $self->sqlSelectAllHashref(
		"nickname",
		"nickname, value",
		"users, users_param",
		"users.uid = users_param.uid
			AND users.seclev > 1
			AND users_param.name='admin_clearpass'
			AND users_param.value",
		"LIMIT 999"
	);
}

########################################################
sub countModeratorLog {
	my($self, $yesterday) = @_;

	my $used = $self->sqlCount(
		'moderatorlog', 
		"ts BETWEEN '$yesterday 00:00' AND '$yesterday 23:59:59'"
	);
}

########################################################
# Note, we have to use $slashdb here instead of $self.
sub getSlaveDBLagCount {
	my($self) = @_;
	my $constants = getCurrentStatic();
	my $slashdb = getCurrentDB();
	my $bdu = $constants->{backup_db_user};
	# If there *is* no backup DB, it's not lagged.
	return 0 if !$bdu || $bdu eq getCurrentVirtualUser();

	my $backupdb = getObject('Slash::DB', $bdu);
	# If there is supposed to be a backup DB but we can't contact it,
	# return a large number that is sufficiently noticeable that it
	# should alert people that something is wrong.
	return 2**30 if !$backupdb;

	# Get the actual lag count.  Assume that each file is 2**30
	# (a billion) bytes (should this be a var?).  Yes, the same
	# data is called "File" vs. "Log_File", "Position" vs. "Pos",
	# depending on whether it's on the master or slave side.
	# And on the slave side, for MySQL 4.x, I *think* I want
	# Master_Log_File and Read_Master_Log_Pos but other possible
	# candidates are Relay_Master_Log_File and Exec_master_log_pos
	# respectively.
	my $master = ($slashdb ->sqlShowMasterStatus())->[0];
	my $slave  = ($backupdb->sqlShowSlaveStatus())->[0];
	my $master_filename = $master->{File};
	my $slave_filename  = $slave ->{Log_File} || $slave->{Master_Log_File};
	my($master_file_num) = $master_filename =~ /\.(\d+)$/;
	my($slave_file_num)  = $slave_filename  =~ /\.(\d+)$/;
	my $master_pos = $master->{Position};
	my $slave_pos  = $slave->{Pos} || $slave->{Read_Master_Log_Pos};

	my $count = 2**30 * ($master_file_num - $slave_file_num)
		+ $master_pos - $slave_pos;
	$count = 0 if $count < 0;
	$count = 2**30 if $count > 2**30;
	return $count;
}

########################################################
sub getRepeatMods {
	my($self, $options) = @_;
	my $constants = getCurrentStatic();
	my $ac_uid = $constants->{anonymous_coward_uid};

	my $within = $options->{within_hours} || 96;
	my $limit = $options->{limit} || 50;
	my $min_count = $options->{min_count}
		|| $constants->{mod_stats_min_repeat}
		|| 2;

	my $hr = $self->sqlSelectAllHashref(
		[qw( val orguid destuid )],
		"usersorg.uid AS orguid,
		 usersorg.nickname AS orgnick,
		 COUNT(*) AS c, val,
		 MAX(ts) AS latest,
		 IF(MAX(ts) > DATE_SUB(NOW(), INTERVAL 24 HOUR),
			1, 0) AS isrecent,
		 usersdest.uid AS destuid,
		 usersdest.nickname AS destnick,
		 usersdesti.karma AS destkarma",
		"users AS usersorg,
		 moderatorlog,
		 users AS usersdest,
		 users_info AS usersdesti",
		"usersorg.uid=moderatorlog.uid
		 AND usersorg.seclev < 100
		 AND moderatorlog.cuid=usersdest.uid
		 AND usersdest.uid=usersdesti.uid
		 AND usersdest.uid != $ac_uid",
		"GROUP BY usersorg.uid, usersdest.uid, val
		 HAVING c >= $min_count
			AND latest >= DATE_SUB(NOW(), INTERVAL $within HOUR)
		 ORDER BY c DESC, orguid
		 LIMIT $limit"
	);
	return $hr;
}

########################################################
sub getModM2Ratios {
	my($self, $options) = @_;

	my $reasons = $self->getReasons();
	my @reasons_m2able = grep { $reasons->{$_}{m2able} } keys %$reasons;
	my $reasons_m2able = join(",", @reasons_m2able);
	my $hr = $self->sqlSelectAllHashref(
		[qw( day m2count )],
		"SUBSTRING(ts, 1, 10) AS day,
		 m2count,
		 COUNT(*) AS c",
		"moderatorlog",
		"active=1 AND reason IN ($reasons_m2able)",
		"GROUP BY day, m2count"
	);

	return $hr;
}

########################################################
sub getCommentsByDistinctIPID {
	my($self, $yesterday, $options) = @_;

	my $section_where = "";
	$section_where .= " AND discussions.id = comments.sid
			    AND discussions.section = '$options->{section}'"
		if $options->{section};

	my $tables = 'comments';
	$tables .= ", discussions" if $options->{section};

	my $used = $self->sqlSelectColArrayref(
		'ipid', $tables, 
		"date BETWEEN '$yesterday 00:00' AND '$yesterday 23:59:59'
		 $section_where",
		'',
		{ distinct => 1 }
	);
}

########################################################
sub getCommentsByDistinctUIDPosters {
	my($self, $yesterday, $options) = @_;

	my $section_where = "";
	$section_where .= " AND discussions.id = comments.sid
			    AND discussions.section = '$options->{section}'"
		if $options->{section};

	my $tables = 'comments';
	$tables .= ", discussions" if $options->{section};

	my $used = $self->sqlSelect(
		'count(DISTINCT uid)', $tables, 
		"date BETWEEN '$yesterday 00:00' AND '$yesterday 23:59:59'
		 $section_where",
		'',
		{ distinct => 1 }
	);
}

########################################################
sub getAdminModsInfo {
	my($self, $yesterday, $weekago) = @_;

	# First get the count of upmods and downmods performed by each admin.
	my $m1_uid_val_hr = $self->sqlSelectAllHashref(
		[qw( uid val )],
		"moderatorlog.uid AS uid, val, nickname, COUNT(*) AS count",
		"moderatorlog, users",
		"users.seclev > 1 AND moderatorlog.uid=users.uid
		 AND ts BETWEEN '$yesterday 00:00' AND '$yesterday 23:59:59'",
		"GROUP BY moderatorlog.uid, val"
	);

	# Now get a count of fair/unfair counts for each admin.
	my $m2_uid_val_hr = $self->sqlSelectAllHashref(
		[qw( uid val )],
		"users.uid AS uid, metamodlog.val AS val, users.nickname AS nickname, COUNT(*) AS count",
		"metamodlog, moderatorlog, users",
		"users.seclev > 1 AND moderatorlog.uid=users.uid
		 AND metamodlog.mmid=moderatorlog.id
		 AND metamodlog.ts BETWEEN '$yesterday 00:00' AND '$yesterday 23:59:59'",
		"GROUP BY users.uid, metamodlog.val"
	);

	# If nothing for either, no data to return.
	return { } if !%$m1_uid_val_hr && !%$m2_uid_val_hr;

	# Get the history of moderation fairness for all admins from the
	# last month.  This reads the last 30 days worth of stats_daily
	# data (not counting today, which will be added to that table
	# shortly).  Set up both the {count} and {nickname} fields for
	# each combination of uid and 1/-1 fairness.
	my $m2_history_mo_hr = $self->sqlSelectAllHashref(
		"name",
		"name, SUM(value) AS count",
		"stats_daily",
		"name LIKE 'm%fair_%' AND day > DATE_SUB(NOW(), INTERVAL 732 HOUR)",
		"GROUP BY name"
	);
	my $m2_uid_val_mo_hr = { };
	for my $name (keys %$m2_history_mo_hr) {
		my($fairness, $uid) = $name =~ /^m2_((?:un)?fair)_admin_(\d+)$/;
		next unless defined($fairness);
		$fairness = ($fairness eq 'unfair') ? -1 : 1;
		$m2_uid_val_mo_hr->{$uid}{$fairness}{count} =
			$m2_history_mo_hr->{$name}{count};
	}
	if (%$m2_uid_val_mo_hr) {
		my $m2_uid_nickname = $self->sqlSelectAllHashref(
			"uid",
			"uid, nickname",
			"users",
			"uid IN (" . join(",", keys %$m2_uid_val_mo_hr) . ")"
		);
		for my $uid (keys %$m2_uid_nickname) {
			for my $fairness (qw( -1 1 )) {
				$m2_uid_val_mo_hr->{$uid}{$fairness}{nickname} =
					$m2_uid_nickname->{$uid}{nickname};
				$m2_uid_val_mo_hr->{$uid}{$fairness}{count} +=
					$m2_uid_val_hr->{$uid}{$fairness}{count};
			}
		}
	}

	# For comparison, get the same stats for all users on the site and
	# add them in as a phony admin user that sorts itself alphabetically
	# last.  Hack, hack.
	my($total_nick, $total_uid) = ("~Day Total", 0);
	my $m1_val_hr = $self->sqlSelectAllHashref(
		"val",
		"val, COUNT(*) AS count",
		"moderatorlog",
		"ts BETWEEN '$yesterday 00:00' AND '$yesterday 23:59:59'",
		"GROUP BY val"
	);
	$m1_uid_val_hr->{$total_uid} = {
		uid =>	$total_uid,
		  1 =>	{ nickname => $total_nick, count => $m1_val_hr-> {1}{count} },
		 -1 =>	{ nickname => $total_nick, count => $m1_val_hr->{-1}{count} },
	};
	my $m2_val_hr = $self->sqlSelectAllHashref(
		"val",
		"val, COUNT(*) AS count",
		"metamodlog",
		"ts BETWEEN '$yesterday 00:00' AND '$yesterday 23:59:59'",
		"GROUP BY val"
	);
	$m2_uid_val_hr->{$total_uid} = {
		uid =>	$total_uid,
		  1 =>	{ nickname => $total_nick, count => $m2_val_hr-> {1}{count} },
		 -1 =>	{ nickname => $total_nick, count => $m2_val_hr->{-1}{count} },
	};

	# Build a hashref with one key for each admin user, and subkeys
	# that give data we will want for stats.
	my($nup, $ndown, $nfair, $nunfair, $percent);
	my @m1_keys = sort keys %$m1_uid_val_hr;
	my @m2_keys = sort keys %$m2_uid_val_hr;
	my %all_keys = map { $_ => 1 } @m1_keys, @m2_keys;
	my @all_keys = sort keys %all_keys;
	my $hr = { };
	for my $uid (@m1_keys) {
		my $nickname = $m1_uid_val_hr->{$uid} {1}{nickname}
			|| $m1_uid_val_hr->{$uid}{-1}{nickname}
			|| "";
		next unless $nickname;
		$nup   = $m1_uid_val_hr->{$uid} {1}{count} || 0;
		$ndown = $m1_uid_val_hr->{$uid}{-1}{count} || 0;
		$percent = ($nup+$ndown > 0)
			? $nup*100/($nup+$ndown)
			: 0;
		# Add the m1 data for this admin.
		$hr->{$nickname}{uid} = $uid;
		$hr->{$nickname}{m1_up} = $nup;
		$hr->{$nickname}{m1_down} = $ndown;
		# If this admin had m1 activity today but no m2 activity,
		# blank out that field.
		if (!exists($m2_uid_val_hr->{$uid})) {
			# $hr->{$nickname}{m2_fair} = 0;
			# $hr->{$nickname}{m2_unfair} = 0;
		}
	}
	for my $uid (@all_keys) {
		my $nickname =
			   $m2_uid_val_hr->{$uid} {1}{nickname}
			|| $m2_uid_val_hr->{$uid}{-1}{nickname}
			|| $m2_uid_val_mo_hr->{$uid} {1}{nickname}
			|| $m2_uid_val_mo_hr->{$uid}{-1}{nickname}
			|| "";
		next unless $nickname;
		$nfair   = $m2_uid_val_hr->{$uid} {1}{count} || 0;
		$nunfair = $m2_uid_val_hr->{$uid}{-1}{count} || 0;
		$percent = ($nfair+$nunfair > 0)
			? $nunfair*100/($nfair+$nunfair)
			: 0;
		# Add the m2 data for this admin.
		$hr->{$nickname}{uid} = $uid;
		# Also calculate overall-month percentage.
		my $nfair_mo   = $m2_uid_val_mo_hr->{$uid} {1}{count} || 0;
		my $nunfair_mo = $m2_uid_val_mo_hr->{$uid}{-1}{count} || 0;
		$percent = ($nfair_mo+$nunfair_mo > 0)
			? $nunfair_mo*100/($nfair_mo+$nunfair_mo)
			: 0;
		# Set another few data points.
		$hr->{$nickname}{m2_fair} = $nfair;
		$hr->{$nickname}{m2_unfair} = $nunfair;
		$hr->{$nickname}{m2_fair_mo} = $nfair_mo;
		$hr->{$nickname}{m2_unfair_mo} = $nunfair_mo;
		# If this admin had m2 activity today but no m1 activity,
		# blank out that field.
		if (!exists($m1_uid_val_hr->{$uid})) {
			# Not really necessary
			# $hr->{$nickname}{m1_up} = 0;
			# $hr->{$nickname}{m1_down} = 0;
		}
	}

	return $hr;
}

########################################################
sub countSubmissionsByDay {
	my($self, $yesterday, $options) = @_;

	my $where = "time BETWEEN '$yesterday 00:00' AND '$yesterday 23:59:59'";
	$where .= " AND section = '$options->{section}'" if $options->{section};

	my $used = $self->sqlCount(
		'submissions', 
		$where
	);
}

########################################################
sub countSubmissionsByCommentIPID {
	my($self, $yesterday, $ipids, $options) = @_;
	return unless @$ipids;
	my $slashdb = getCurrentDB();
	my $in_list = join(",", map { $slashdb->sqlQuote($_) } @$ipids);

	my $where = "(time BETWEEN '$yesterday 00:00' AND '$yesterday 23:59:59') AND ipid IN ($in_list)";
	$where .= " AND section = '$options->{section}'" if $options->{section};

	my $used = $self->sqlCount(
		'submissions', 
		$where
	);
}

########################################################
sub countModeratorLogHour {
	my($self, $yesterday) = @_;

	my $modlog_hr = $self->sqlSelectAllHashref(
		"val",
		"val, COUNT(*) AS count",
		"moderatorlog",
		"ts BETWEEN '$yesterday 00:00' AND '$yesterday 23:59:59'",
		"GROUP BY val"
	);
	
	return $modlog_hr;
}

########################################################
sub countCommentsDaily {
	my($self, $yesterday, $options) = @_;

	my $tables = 'comments';
	$tables .= ", submissions" if $options->{section};

	my $section_where = "";
	$section_where .= " AND discussions.id = comments.sid
			    AND discussions.section = '$options->{section}'"
		if $options->{section};
	
	# Count comments posted yesterday... using a primary key,
	# if it'll save us a table scan.  On Slashdot this cuts the
	# query time from about 12 seconds to about 0.8 seconds.
	my $max_cid = $self->sqlSelect("MAX(comments.cid)", $tables);
	my $cid_limit_clause = "";
	if ($max_cid > 300_000) {
		# No site can get more than 100K comments a day in
		# all its sections combined.  It is decided.  :)
		$cid_limit_clause = "cid > " . ($max_cid-100_000)
			. " AND ";
	}

	my $comments = $self->sqlSelect(
		"COUNT(*)",
		"comments",
		"$cid_limit_clause
		 date BETWEEN '$yesterday 00:00' AND '$yesterday 23:59:59'
		 $section_where"
	);

	return $comments; 
}
########################################################
sub countBytesByPage {
	my($self, $op, $yesterday, $options) = @_;

	my $where = "ts BETWEEN '$yesterday 00:00' AND '$yesterday 23:59:59'";
	$where .= " AND op='$op'"
		if $op;
	$where .= " AND section='$options->{section}'"
		if $options->{section};

	# The "no_op" option can take either a scalar for one op to exclude,
	# or an arrayref of multiple ops to exclude.
	my $no_op = $options->{no_op} || [ ];
	$no_op = [ $no_op ] if $options->{no_op} && !ref($no_op);
	if (@$no_op) {
		my $op_not_in = join(",", map { $self->sqlQuote($_) } @$no_op);
		$where .= " AND op NOT IN ($op_not_in)";
	}

	$self->sqlSelect("sum(bytes)", "accesslog", $where);
}

########################################################
sub countUsersByPage {
	my($self, $op, $yesterday, $options) = @_;
	my $where = "op='$op' AND "
		if $op;
	$where .= "section='$options->{section}' AND "
		if $options->{section};
	$where .= "ts BETWEEN '$yesterday 00:00' AND '$yesterday 23:59:59'";
	$self->sqlSelect("count(DISTINCT uid)", "accesslog", $where);
}

########################################################
sub countDailyByPage {
	my($self, $op, $yesterday, $options) = @_;

	my $where = "ts BETWEEN '$yesterday 00:00' AND '$yesterday 23:59:59'";
	$where .= " AND op='$op'"
		if $op;
	$where .= " AND section='$options->{section}'"
		if $options->{section};

	# The "no_op" option can take either a scalar for one op to exclude,
	# or an arrayref of multiple ops to exclude.
	my $no_op = $options->{no_op} || [ ];
	$no_op = [ $no_op ] if $options->{no_op} && !ref($no_op);
	if (@$no_op) {
		my $op_not_in = join(",", map { $self->sqlQuote($_) } @$no_op);
		$where .= " AND op NOT IN ($op_not_in)";
	}

	$self->sqlSelect("count(*)", "accesslog", $where);
}

########################################################
sub countDailyByPageDistinctIPID {
	# This is so lame, and so not ANSI SQL -Brian
	my($self, $op, $yesterday, $options) = @_;
	my $where = "op='$op' AND "
		if $op;
	$where .= "section='$options->{section}' AND "
		if $options->{section};
	$where .= "ts BETWEEN '$yesterday 00:00' AND '$yesterday 23:59:59'";
	$self->sqlSelect("count(DISTINCT host_addr)", "accesslog", $where);
}

########################################################
sub countDaily {
	my($self, $options) = @_;
	my %returnable;

	my $constants = getCurrentStatic();
	my $section_where = $options->{section}
		? " AND section = '$options->{section}'"
		: '';

	my($min_day_id, $max_day_id) = $self->sqlSelect(
		"MIN(id), MAX(id)",
		"accesslog",
		"TO_DAYS(NOW()) - TO_DAYS(ts)=1 $section_where"
	);
	$min_day_id ||= 1; $max_day_id ||= 1;
	my $yesterday_clause = "(id BETWEEN $min_day_id AND $max_day_id) $section_where";

	# For counting the total, we used to just do a COUNT(*) with the
	# TO_DAYS clause.  If we separate out the count of each op, we can
	# in perl be a little more specific about what we're counting.
	# And it's about as fast for the DB.
	my $totals_op = $self->sqlSelectAllHashref(
		"op",
		"op, COUNT(*) AS count",
		"accesslog",
		$yesterday_clause,
		"GROUP BY op"
	);
	$returnable{total} = 0;
	my %excl_countdaily = map { $_, 1 } @{$constants->{op_exclude_from_countdaily}};
	for my $op (keys %$totals_op) {
		# If this op is on the list of ops to exclude,
		# don't add its count into the daily total.
		next if $excl_countdaily{$op};
		$returnable{total} += $totals_op->{$op}{count};
	}

	my $c = $self->sqlSelectMany("COUNT(*)", "accesslog",
		$yesterday_clause, "GROUP BY host_addr $section_where");
	$returnable{unique} = $c->rows;
	$c->finish;

	$c = $self->sqlSelectMany("COUNT(*)", "accesslog",
		$yesterday_clause, "GROUP BY uid $section_where");
	$returnable{unique_users} = $c->rows;
	$c->finish;

#	# This code doesn't work yet, I think because of the commented-out
#	# article .shtml logging code in Slash::Apache::IndexHandler.
#	# - Jamie 2002/07/12
#	$returnable{total_static} = $self->sqlCount(
#		"accesslog",
#		"$yesterday_clause AND dat='shtml'");
#	$returnable{total_dynamic} = $returnable{total} - $returnable{static};

	$c = $self->sqlSelectMany("dat, COUNT(*)", "accesslog",
		"$yesterday_clause AND (op='index' OR dat='index') $section_where",
		"GROUP BY dat");

	my(%indexes, %articles, %commentviews);

	while (my($sect, $cnt) = $c->fetchrow) {
		$indexes{$sect} = $cnt;
	}
	$c->finish;

	$c = $self->sqlSelectMany("dat, COUNT(*), op", "accesslog",
		"$yesterday_clause AND op='article' $section_where",
		"GROUP BY dat");

	while (my($sid, $cnt) = $c->fetchrow) {
		$articles{$sid} = $cnt;
	}
	$c->finish;

	$returnable{'index'} = \%indexes;
	$returnable{'articles'} = \%articles;


	return \%returnable;
}

sub DESTROY {
	my($self) = @_;
	$self->{_dbh}->disconnect if !$ENV{GATEWAY_INTERFACE} && $self->{_dbh};
}


1;

__END__

# Below is the stub of documentation for your module. You better edit it!

=head1 NAME

Slash::Stats - Stats system splace

=head1 SYNOPSIS

	use Slash::Stats;

=head1 DESCRIPTION

This is the Slash stats system.

Blah blah blah.

=head1 AUTHOR

Brian Aker, brian@tangent.org

=head1 SEE ALSO

perl(1).

=cut
