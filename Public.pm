package Sparky::Public;

# $Header: /u00/home/sparky/dev/lib/Sparky/Public/RCS/Public.pm,v 1.6 2001/05/31 16:45:43 sparky Exp $
# Copyright (c) 2001 by Hotsos Enterprises, Ltd. All rights reserved.
# Cary Millsap (cary.millsap@hotsos.com)

require 5.005_62;
use strict;
use warnings;

require Exporter;

our @ISA       = qw(Exporter);
our @EXPORT    = qw(
	$datestamp $datefmt SEC TIM SESSION_SPARKY SESSION_SUT
	waitfor
	trcfilter
	hstr2time htime2str trcstr2time
	checkenv fnum min max
);
our @EXPORT_OK = qw();
our $VERSION = do { my @r=(q$Revision: 1.6 $=~/\d+/g); sprintf "%d."."%02d"x$#r,@r };

use Carp;
use Date::Format qw(time2str);
use Date::Parse  qw(str2time);
use Time::HiRes  qw(gettimeofday);
use Term::ReadKey;

# for parsing Oracle trace files
our $datestamp = '\d{4}\D\d{2}\D\d{2}\D+\d{2}\D+\d{2}\D+\d{2}\.\d+';  # date stamp format in Oracle trace files

# for output emissions
our $datefmt = "%Y/%m/%d %T";

# Oracle performance diagnostic timing units
use constant SEC =>   1;    # unity: number of seconds per second
use constant TIM => 100;    # number of Oracle clock ticks per second

# session identifiers
use constant SESSION_SPARKY => "-SPARKY";
use constant SESSION_SUT    => "-SUT";


sub waitfor {
    # Cary Millsap 2000/11/14 Brisbane
    # Return time (Epoch seconds) after waiting as instructed

    if (!defined $_[0]) {			# arg is undef
        return gettimeofday;		# return immediately
    } elsif ($_[0] =~ m/^\d+$/) {	# arg is purely numeric
        my $time = $_[0];
        my $now = gettimeofday;
        sleep($time - $now) if $time > $now;
        return gettimeofday;
    } else {						# arg is defined but not numeric
        my $prompt = $_[0];
        return gettimeofday unless (-t STDIN && -t STDERR);
        print STDERR "Press a key$prompt...";
        ReadMode "cbreak";			# use blocking reads (Perl Cookbook pp524-525)
        ReadKey 0;					# await a keypress
        ReadMode "normal";			# back to normal
        my $secs = gettimeofday;
        print STDERR "(", scalar localtime($secs), ")\n";
        return $secs;
    }
}


sub trcfilter {
	my ($sid, $ost0, $ost1, $dbt0, $dbt1, $ofile, @ifiles) = @_;

	# NOTE: @ifiles is a list to accommodate MTS trace files in a future release
	my $ifile = shift @ifiles;

	open IFILE, "<$ifile" or die "$main::program: can't open $ifile: $!";
	open OFILE, ">$ofile" or die "$main::program: can't open $ofile: $!";
	if ($main::opt{v}) {
		print  "\nopened trace file $ifile\n";
		printf "time0=%16.3f %20s\n", $dbt0, htime2str($datefmt, $ost0, 3);
		printf "time1=%16.3f %20s\n", $dbt1, htime2str($datefmt, $ost1, 3);
	}

	my ($ostime, $dbtime) = (0, 0);	# OS and DB clocks (in seconds)
	my $datestamp_line = "";		# true iff clocks are set by "*** $datestamp" to the next event's end time
	# NOTE: Oracle prints "*** $datestamp" at the conclusion of the following event

	# copy the prolog through the "*** SESSION ID: $datestamp" line
	while (defined(my $line = <IFILE>)) {
		if ($line =~ /^\*\*\*\s*($datestamp)\r?$/i) {
			$datestamp_line = $line;	# next event ends at time $1
			$ostime = hstr2time($1);
			$dbtime = $dbt0 + ($ostime - $ost0);
			emit(1, "0a", $dbtime, $ostime, $line);
		} elsif ($line =~ /^\*\*\*\s*SESSION ID:\s*\(\d+\.\d+\)\s*($datestamp)\r?$/i) {
			emit(1, "0b", $dbtime, $ostime, $line);
			last;
		} else {
			emit(1, "0c", $dbtime, $ostime, $line);
		}
	}

	# filter the file's contents
	while (defined(my $line = <IFILE>)) {
		if ($line =~ /^WAIT.*\s+ela=\s*(\d+)\s+/i) {
			my $e = $1 * SEC/TIM;
			if (!$datestamp_line) {
				# update clocks because WAITs don't have a tim
				$dbtime += $e;
				$ostime += $e;
			}
			my ($loc, $e1) = xoi($dbtime-$e, $dbtime, $dbt0, $dbt1);
			if (index("LR", $loc) > -1) {
				emit(0, "1$loc", $dbtime, $ostime, $line);
			} elsif (index("c", $loc) > -1) {
				emit(1, "1$loc", $dbtime, $ostime, $line);
			} else { #if (index("lCr", $loc) > -1) {
				emit(1, "1$loc", $dbtime, $ostime, $datestamp_line) if index("rC",$loc)>-1 and $datestamp_line;
				emit(0, "1x", $dbtime, $ostime, $line);
				$e1 = sprintf "%.0f", $e1*TIM/SEC;
				$line =~ s/ ela=(\s*)\d+ / ela=$1$e1 /;
				emit(1, "1$loc", $dbtime, $ostime, $line);
			}
			$datestamp_line = "";
		} elsif ($line =~ /c=(\d+),e=(\d+),.*,tim=(\d+)/i) {
			my $c   = $1 * SEC/TIM;
			my $e   = $2 * SEC/TIM;
			$dbtime = $3 * SEC/TIM;
			$ostime = $ost0 + ($dbtime - $dbt0);
			my ($loc, $e1) = xoi($dbtime-$e, $dbtime, $dbt0, $dbt1);
			if (index("LR", $loc) > -1) {
				emit(0, "2$loc", $dbtime, $ostime, $line);
			} elsif (index("c", $loc) > -1) {
				emit(1, "2$loc", $dbtime, $ostime, $line);
			} else { #if (index("lCr", $loc) > -1) {
				emit(1, "2$loc", $dbtime, $ostime, $datestamp_line) if index("rC",$loc)>-1 and $datestamp_line;
				emit(0, "2x", $dbtime, $ostime, $line);
				# The following line WILL ALTER THE CPU TIME VALUE, but only in cases where
				# c>e and e==0. We presently believe those cases to be Oracle bugs anyway.
				my $c1 = ($e == 0) ? 0 : sprintf "%.0f", ($e1/$e)*$c * TIM/SEC;
				$e1 = sprintf "%.0f", $e1*TIM/SEC;
				$line =~ s/c=\d+,e=\d+,/c=$c1,e=$e1,/;
				emit(1, "2$loc", $dbtime, $ostime, $line);
			}
			$datestamp_line = "";
		} elsif ($line =~ /^PARSING.*tim=(\d+)/i) {
			$dbtime = $1 * SEC/TIM;
			$ostime = $ost0 + ($dbtime - $dbt0);
			my ($loc, $e1) = xoi($dbtime, $dbtime, $dbt0, $dbt1);
			if (index("LlcCr", $loc) > -1) {
				emit(1, "3$loc", $dbtime, $ostime, $line);
				while (defined($line = <IFILE>)) {
					emit(1, "3$loc", $dbtime, $ostime, $line);
					last if $line =~ /^END OF STMT\r?$/i;
				}
			} else { #if (index("R", $loc) > -1) {
				emit(0, "3$loc", $dbtime, $ostime, $line);
				while (defined($line = <IFILE>)) {
					emit(0, "3$loc", $dbtime, $ostime, $line);
					last if $line =~ /^END OF STMT\r?$/i;
				}
			}
			$datestamp_line = "";
		} elsif ($line =~ /^STAT/i) {
			my ($loc, $e) = xoi($dbtime, $dbtime, $dbt0, $dbt1);
			if (index("lcCrR", $loc) > -1) {
				emit(1, "4$loc", $dbtime, $ostime, $line);
			} else { #if (index("L", $loc) > -1) {
				emit(0, "4$loc", $dbtime, $ostime, $line);
			}
		} elsif ($line =~ /^\*\*\*\s*($datestamp)\r?$/i) {
			$datestamp_line = $line;	# next event ends at time $1
			$ostime = hstr2time($1);
			$dbtime = $dbt0 + ($ostime - $ost0);
			my ($loc, $e) = xoi($dbtime, $dbtime, $dbt0, $dbt1);
			if (index("lcCr", $loc) > -1) {
				emit(1, "5$loc", $dbtime, $ostime, $line);
			} else { #if (index("LR", $loc) > -1) {
				emit(0, "5$loc", $dbtime, $ostime, $line);
			}
		} elsif ($line =~ /DUMP FILE SIZE IS LIMITED/i) {
			emit(1, "6 ", $dbtime, $ostime, $line);
		} else {
			my ($loc, $e) = xoi($dbtime, $dbtime, $dbt0, $dbt1);
			if (index("lcCr", $loc) > -1) {
				emit(1, "7$loc", $dbtime, $ostime, $line);
			} else { #if (index("LR", $loc) > -1) {
				emit(0, "7$loc", $dbtime, $ostime, $line);
			}
		}
	}
	# clean up
	close OFILE or die "$main::program: can't close $ofile";
	close IFILE or die "$main::program: can't close $ifile";

	return 1;
}



sub xoi {
	# return interval intersection information (position, elapsed)
	# - position is chosen from {L, l, c, C, r, R} (see code for definitions),
	#   depending upon relation of supplied interval to [$dbt0,$dbt1]
	# - elapsed is seconds of intersection elapsed duration
	my ($t0, $t1, $dbt0, $dbt1) = @_;
	if ($t0 < $dbt0) {							# -(---[-----]-----
		if ($t1 < $dbt0) {						# -(-)-[-----]-----
			return ("L", 0);
		} elsif ($t1 <= $dbt1) {				# -(---[ee)--]-----
			return ("l", $t1 - $dbt0);
		} else {								# -(---[eeeee]---)-
			return ("C", $dbt1 - $dbt0);
		}
	} elsif ($t0 <= $dbt1) {					# -----[-(---]-----
		if ($t1 <= $dbt1) {						# -----[-(e)-]-----
			return ("c", $t1 - $t0);
		} else {								# -----[-(eee]---)-
			return ("r", $dbt1 - $t0);
		}
	} else {									# -----[-----]---(-
		return ("R", 0);
	}
}


sub emit {
	my ($print, $id, $dbtime, $ostime, $line) = @_;
	printf "%1s %3s %16.3f %s %s",
		($print?"Y":""),
		$id,
		$dbtime,
		htime2str($datefmt, $ostime, 3),
		$line
	if $main::opt{v};
	print OFILE $line if $print;
}


sub htime2str {
    # HiRes time2str() converter
    my ($format, $n, $p) = @_;
    my $frac = sprintf "%0.${p}f", $n;
    $frac =~ s/^.*\.//g;
    return time2str($format, $n).".$frac";
}


sub hstr2time {
    # HiRes str2time() converter
    my ($s) = @_;
    my $frac = $s;
    $frac =~ s/^.*\.//g;
    return str2time($s) . ".$frac";
}


sub trcstr2time {
	# convert Oracle trace file date stamp into a high-precision Epoch time
	if ($_[0] =~ /(\d{4})\D(\d{2})\D(\d{2})\D+(\d{2})\D(\d{2})\D(\d{2})\.(\d+)/) {
		return hstr2time("$1/$2/$3 $4:$5:$6.$7");
	} else {
		return undef;
	}
}


sub checkenv {
	my @envvars = @_;
	my $errors = 0;
	print "\nenvironment:\n" if $main::opt{v};
	for my $v (@envvars) {
		if (!defined $ENV{$v} or $ENV{$v} eq "") {
			warn "$main::program: $v environment variable not set\n";
			$errors++;
		} else {
			printf "\t%20s = %-40s\n", $v, $ENV{$v} if $main::opt{v};
		}
	}
	croak "$main::program: required environment variables not set" if $errors;
}


sub fnum {
	# return numeric value in %.${precision}f format, with commas
	my ($text, $precision) = @_;
	#carp "undefined p1" unless defined $text;
	#carp "undefined p2" unless defined $precision;
	$text = reverse sprintf "%.${precision}f", $text;
	$text =~ s/(\d\d\d)(?=\d)(?!\d*\.)/$1,/g;
	return scalar reverse $text;
}


sub max {
	my $max = shift;
	for my $n (@_) {
		$max = $n if $n > $max;
	}
	return $max;
}


sub min {
	my $min = shift;
	for my $n (@_) {
		$min = $n if $n < $min;
	}
	return $min;
}



1;


__END__


=head1 NAME

Sparky::Public - support functions for Sparky data collector and profiler

=head1 SYNOPSIS

  use Sparky::Public;

  if ($line =~ /$datestamp/i) { ... }

  $secs = $tim * SEC/TIM;

  $time = waitfor($number);
  $time = waitfor($string);

  trcfilter($sid, $ost0, $ost1, $dbt0, $dbt1, $ofile, @ifiles);

  $t = hstr2time($string);
  $str = htime2str($fmt, $time, $digits);

  checkenv(@envvars);

  printf "%8s\n", fnum($text, $precision);

  $min = min(@list);
  $max = max(@list);


=head1 DESCRIPTION

=over 4

=item C<$datestamp>

C<$datestamp> is a regular expression that matches the date stamp that an
Oracle session prints to its trace file.

=item C<TIM>, C<SEC>

C<TIM> is the number of Oracle clock ticks per second. C<SEC> is unity (the
number of seconds per second). We provide B<SEC> so that the programmer
may refer naturally to B<SEC/TIM> or B<TIM/SEC> in code that requires
unit conversions.

=item C<waitfor>

  $time = waitfor($number);
  $time = waitfor($string);

B<waitfor()> waits until a specified event occurs before returning control
to its caller. The return value in all cases is the time (in seconds since
the Epoch) at which control was returned to the caller. If its argument
is undefined, then it returns control immediately to its caller.

If the argument to B<waitfor()> is a whole number (matching the pattern
/\d+/), then it is assumed to be a time (in seconds since the Epoch) at which
control is to be returned to the caller. If C<$number> represents a time
in the past, then B<waitfor()> returns control immediately to its caller.

If the argument to B<waitfor()> is defined but does not match the purely
numeric pattern discussed previously, then the argument is assumed to be
an interactive prompt. First, B<waitfor()> will determine whether STDERR
and STDIN are tty devices. If they are tty devices, then B<waitfor()> will
prompt STDERR with the interpolated string "Press a key$string..." and
await a keypress on STDIN. Upon receiving a keypress, B<waitfor()> will
complete the prompt line by writing the keypress time followed by "\n"
to STDERR. If STDERR and STDIN are not tty devices, then B<waitfor()>
will return immediately.

The B<waitfor()> function is designed to simplify the specification of
performance analysis observation intervals defined in real-time. This
example shows how to use B<waitfor()> to define an observation interval
interactively:

  # interactive style
  $t0 = waitfor(" to begin observation interval");
  # take a snapshot
  $t1 = waitfor(" to end observation interval  ");
  # take a snapshot
  printf "Observation interval duration: %.3f sec\n", $t1-$t0;

The resulting session will look like this:

  Press a key to begin observation interval...(Thu Apr  5 16:36:19 2001)
  Press a key to end observation interval  ...(Thu Apr  5 16:36:20 2001)
  Observation interval duration: 1.168 sec

The B<waitfor()> function can also be used as an alternative to B<at(1)>
or B<cron(1M)>, which can be especialy helpful on systems without adequate
scheduling facilities:

  # batch style
  use Date::Parse;
  for (7..18) {
      my $t0 = scalar localtime str2time("$_:00");
      waitfor(str2time($time));
      ...
  }

The resulting session will take a snapshot every hour upon the hour from
7:00am through 6:00pm (07.00-18.00).

=item C<trcfilter>

  trcfilter($sid, $ost0, $ost1, $dbt0, $dbt1, $ofile, @ifiles);

<trcfilter> employs Hotsos research results to filter Oracle trace files
created by event 10046 level 1, 4, 8, or 12. The input file filtration
criterion is a time range, expressed as observation interval beginning
and ending times on two separate clocks.

The first clock is the OS time clock, recorded in Epoch seconds and
fractions of seconds. C<$ost0> and C<$ost1> are interval beginning and
end times, respectively. The second clock is the database time clock, as
recorded in C<v$timer.hsecs>, and converted to seconds and fractions of
seconds. C<$dbt0> and C<$dbt1> are the db clock times that correspond to
C<$ost0> and C<$ost1>. C<trcfilter> equates the t0 times of these two clocks.

C<$ofile> is the name of the file to which the filtered trace data will
be written. The first file named in the C<@ifiles> list is the name of
the input trace file to be filtered.

C<$sid> is presently only a placeholder. In a future revision of
C<trcfilter>, this parameter will denote the id of the session whose
trace data may be scattered across multiple input files by using Oracle's
Multi-Threaded Server option (hence the reason that C<@ifiles> is a list,
and not a scalar).

C<trcfilter> passes the trace file preamble unaltered. For trace file lines
that represent events that cross a time interval boundary, C<trcfilter>
emits a line whose elapsed and CPU times (where applicable) are adjusted
to reflect only the duration that exists within the specified observation
interval. C<trcfilter> emits all "PARSING IN CURSOR" actions that occur
before C<$ost0> (or, equivalently, before C<$dbt0>). It emits all "STAT"
actions that occur after C<$ost1> (C<$dbt1>).

=item C<hstr2time>

  $t = hstr2time($string);

C<hstr2time> sits atop the Date::Parse C<str2time> function call. If
C<$string> has a fraction-of-a-second component, C<hstr2time> will preserve
that information in its return value.

=item C<htime2str>

  $str = htime2str($fmt, $time, $digits);

C<htime2str> sits atop the Date::Format C<time2str> function call. C<$digits>
is an integer defining the number of digits past the decimal point that
should be included in the string return value.

=item C<checkenv>

  checkenv(@envvars);

C<checkenv> tests to ensure that a list of OS environment variables are
set. If one or more variables are unset, then C<checkenv> will print a
warning about each unset variable and then exit with a call to C<die>.

=item C<fnum>

  printf "%8s\n", fnum($text, $precision);

C<fnum> returns C<$text> in a friendly format with commas as thousands
separators, and with C<$precision> digits to the right of the decimal point.

=item C<min>, C<max>

  $min = min(@list);
  $max = max(@list);

C<min> returns the numerically smallest element of a list, and C<max>
returns the numerically largest element of a list.


=back

=head1 ENVIRONMENT

Many Sparky::Public modules require that C<$main::program> be set to the name
of the calling executable program. It is usually set with C<$main::program =
basename $0>.

If the value C<$main::opt{v}> is set, then many Sparky::Public functions
will print verbose information.


=head1 AUTHOR

Cary Millsap, cary.millsap@hotsos.com.

=head1 SEE ALSO

perl(1).

=cut
