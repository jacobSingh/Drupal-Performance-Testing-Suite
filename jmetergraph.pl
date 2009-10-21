#!/usr/bin/perl
#---
# Original script by Christoph Meissner (email unknown)
# Taken from http://wiki.apache.org/jakarta-jmeter-data/attachments/LogAnalysis/attachments/jmetergraph.pl
# Fixes by George Barnett (george@alink.co.za)
#
# Fixes:
# - Modified to 'use strict'
# - Fixed scoping of various variables
# - Added DEBUG print option
#
# Script Options:
# perl jmetergraph.pl  [-alllb] [-stddev] [-range] <jtl file 1> [ ... <jtl file n>]
# -alllb [Script does not draw stacked chart for requests that are < 1% of total.  This disables this behaviour]
# -stddev [Will draw the std dev]
# -range [Wil draw request range]
#
#---
#
# This script parses xml jtl files created by jmeter.
# It extracts timestamps, active threads and labels from it.
#
# Further, based on this data
# it builds below chart files (see sample files):
#
# 1. one chart containing the overall response times related to active threads.
#    The resulting png file is named 'entire_user.png'.
#
# 2. one chart containing the overall response times related to throughput
#    The resulting png file is named 'entire_throughput.png'.
#
# 3. one chart that will contain bars for each label
#    which were stacked over response intervals (expressed in msec)
#    The resulting png file is named 'ChartStacked.png'
#    
# 4. one chart that will contain stacked bars for each label
#    which were stacked over response intervals (expressed in msec)
#    The resulting png file is named 'ChartStackedPct.png'
#
# 5. one chart per label containing response times related to active threads and throughput
#    This chart png is named like the label itself with the non-word characters substituted by '_'
#    If it is related to active threads then '_user' is appended to the graph's file name -
#    otherwise a '_throughput'.
#
# IMPORTANT:
# ==========
# The script works best with jmeter log format V2.1.
# I never tested it on log's of either older or newer versions.
# Also, I was too sluggish to include an XML parser.
# Thus the script parses the jtl files by using regex.
#
# The graphs are built depending on the names of the labels of your requests.
# Thus group your label names with this in mind
# when you are about to create your jmeter testplan,
#
# Also, only the labels on the 1st level are considered.
# They accumulate the response time, active users and throughput 
# for all sub levels.
#
#
# FAQ:
# ====
# How to make this script to create proper charts?
#
# Open your testplan with jmeter and
# 1. insert listener 'Aggregate Report' (unless not present already).
# 2. invoke 'Configure' there
# 3. make sure that below checks are activated at least:
#    'Save as XML'
#    'Save Label'
#    'Save Time Stamp'
#    'Save Thread Name'
#    'Save Active Thread Counts'
#    'Save Elapsed Time'
# 4. tell 'Aggregate Report' to write all data into a file
# 5. when building your testplan
#    you should name your critical request samplers in a way that data can be grouped into it
#    (eg. 'Login', 'Host request', 'continue page', 'Req Database xyz', ...)
#
# Perl requisites:
# 6. install the perl 'GD' package
# 7. install the perl 'Chart' package
# 8. test perl.
#    This means that
#	    perl -MGD -MChart::Lines -MChart::Composite -MChart::StackedBars
#    shouldn't fail
#
# To run the script:
# perl jmetergraph.pl <jtl file1> <jtl file2> ... <jtl file_n>
# 
# The png graphs will be created in current working directory
# 
# I created this checklist to my best knowledge.
# However, if it fails in your computer environment, ...
# 
#---

use strict;
use Chart::StackedBars;
use Chart::Composite;
use Chart::Lines;

#---
# arguments passed?
#---
my @files = grep {!/^-/ && -s "$_"} @ARGV;
our @args = grep {/^-/ && !-f "$_"} @ARGV;

my $DEBUG = 1;

my %entire = ();
my %glabels = ();
my %gthreads = ();
my $atflag = 0;	# if active threads found then according graphs will be created
#---
# data received within this intervall will be averaged into one result
#---

my $collectinterval = 180;		# 60 seconds
#---
# cusps aggregate response times
#---
our @cusps = (200, 500, 1000, 2000, 5000, 10000, 60000);

#---
# labels determine the name of output charts
#---
our @labels = ();
our @threads = ();

#---
# intermediate values
#---
our %timestamps = ();
our $respcount = 0;
our $measures = 0;

# Some variables.  Cunt who wrote this script didn't use strict so it's fucked ITO scoping
my ($entireta,$entirecnt,$entireby);
my ($respcount,$sumresptimes,$sumSQresptimes); 

#---
# define colors for stacked bar charts
#---
our %colors = (
	dataset0 => "green",
	dataset1 => [0, 139, 139], # dark cyan
	dataset2 => [255, 215,0],  # gold
	dataset3 => "DarkOrange",
	dataset4 => "red",
	dataset5 => [255, 0, 0],   # red
	dataset6 => [139, 0, 139], # dark magenta
	dataset7 => [0, 0, 0],	   # black
);

#---
# here we go thru all files and collect data
#---

while(my $file = shift(@files)) {
	print "Opening file $file\n" if $DEBUG;
	open(IN, "<$file") || do  {
		print $file, " ", $!, "\n";
		next;
	};

	print "Parsing data from $file\n" if $DEBUG;
	while(<IN>) {
		my ($time,$timestamp,$success,$label,$thread,$latency,$bytes,$DataEncoding,$DataType,$ErrorCount,$Hostname,$NumberOfActiveThreadsAll,$NumberOfActiveThreadsGroup,$ResponseCode,$ResponseMessage,$SampleCount);
		if(/^<(sample|httpSample)\s/) {

			($time) = (/\st="(\d+)"/o);
			($timestamp) = (/\sts="(\d+)"/o);
			($success) = (/\ss="(.+?)"/o);
			($label) = (/\slb="(.+?)"/o);
			($thread) = (/\stn="(.+?)"/o);
			($latency) = (/\slt="(\d+)"/o);
			($bytes) = (/\sby="(\d+)"/o);
			($DataEncoding) = (/\sde="(\d+)"/o);
			($DataType) = (/\sdt="(.+?)"/o);
			($ErrorCount) = (/\sec="(\d+)"/o);
			($Hostname) = (/\shn="(.+?)"/o);
			($NumberOfActiveThreadsAll) = (/\sna="(\d+)"/o);
			($NumberOfActiveThreadsGroup) = (/\sng="(\d+)"/o);
			($ResponseCode) = (/\src="(.+?)"/o);
			($ResponseMessage) = (/\srm="(.+?)"/o);
			($SampleCount) = (/\ssc="(\d+)"/o);

		} elsif(/^<sampleResult/) {
			($time) = (/\stime="(\d+)"/o);
			($timestamp) = (/timeStamp="(\d+)"/o);
			($success) = (/success="(.+?)"/o);
			($label) = (/label="(.+?)"/o);
			($thread) = (/threadName="(.+?)"/o);
		} else {
			next;
		}

		$label =~ s/\s+$//g;
		$label =~ s/^\s+//g;
		$label =~ s/[\W\s]+/_/g;

		next if($label =~ /^garbage/i);	# don't count these labels into statistics

		#---
		# memorize labels
		#---
	       	if(!grep(/^$label$/, @labels)) {
			push(@labels, $label);
			print "Found new label: $label\n" if $DEBUG;
		}
		$glabels{$label}{'respcount'} += 1;
		$entire{'respcount'} += 1;

		#---
		# memorize timestamps
		#---

		my $tstmp = int($timestamp / (1000 * $collectinterval)) * $collectinterval;
		$timestamps{$tstmp} += 1;

		#---
		# cusps
		#---
		for(my $i = 0; $i <= $#cusps; $i++) {
			if(($time <= $cusps[$i]) || (($i == $#cusps) && ($time > $cusps[$i]))) {
				$glabels{$label}{$cusps[$i]} += 1;
				$entire{$cusps[$i]} += 1;
				last;
			}
		}
		#---
		# stddev
		#---
		$respcount += 1;
		$sumresptimes += $time;
		$sumSQresptimes += ($time ** 2);
		if($respcount > 1) {
			my $stddev = sqrt(($respcount * $sumSQresptimes - $sumresptimes ** 2) /
				($respcount * ($respcount - 1)));

			$entire{$tstmp, 'stddev'} = $glabels{$label}{$tstmp, 'stddev'} = $stddev;

		}

		#---
		# avg
		#---
		$entire{$tstmp, 'avg'} = $sumresptimes / $respcount;

		$glabels{$label}{$tstmp, 'responsetime'} += $time;
		$glabels{$label}{$tstmp, 'respcount'} += 1;
		$glabels{$label}{$tstmp, 'avg'} = int($glabels{$label}{$tstmp, 'responsetime'} / $glabels{$label}{$tstmp, 'respcount'});

		#---
		# active threads
		#---

		if(!$entire{$tstmp, 'activethreads'}) {
			$entireta = 0;
			$entirecnt = 0;
			$entireby = 0;
		}

		if($NumberOfActiveThreadsAll > 0) {
			$atflag = 1;
		}

		$entirecnt += 1;

		if($atflag == 1) {
			$entireta += $NumberOfActiveThreadsAll;
			$entire{$tstmp, 'activethreads'} = int($entireta / $entirecnt);
	
			if(!$glabels{$label}{$tstmp, 'activethreads'}) {
				$glabels{$label}{$tstmp, 'lbta'} = 0;
				$glabels{$label}{$tstmp, 'lbby'} = 0;
			}
			$glabels{$label}{$tstmp, 'lbta'} += $NumberOfActiveThreadsAll;
			$glabels{$label}{$tstmp, 'activethreads'} = sprintf("%.0f", $glabels{$label}{$tstmp, 'lbta'} / $glabels{$label}{$tstmp, 'respcount'});

		} else {
			#---
			# if NumberOfActiveThreads is not available
			# use threadname to extrapolate active threads later
			#---
			if($NumberOfActiveThreadsAll eq '') {
		       		if(!$gthreads{$thread}{'first'}) {
					$gthreads{$thread}{'first'} = $tstmp;
					push(@threads, $thread);
				}
	
				$gthreads{$thread}{'last'} = $tstmp;
			}
		}

		#---
		# throughput
		#---
		if($bytes > 0) {
			$entireby += $bytes;
			$entire{$tstmp, 'throughput'} = int($entireby / $entirecnt);
	
			$glabels{$label}{$tstmp, 'lbby'} += $bytes;
			$glabels{$label}{$tstmp, 'throughput'} = $glabels{$label}{$tstmp, 'lbby'}; # counts per $collectinterval
		}

	}
	print "Closing $file\n" if $DEBUG;
	close(IN);
}

print "Found $#labels labels\n" if $DEBUG;

# Sort the labels.
print "Sorting labels\n" if $DEBUG;
my @tmplabels = sort @labels;
@labels = @tmplabels;

#---
# if required (no NumbersOfActiveThreads)
# then extrapolate users
#---
if($atflag == 0) {
	print "using timestamps to calculate active threads\n";
	my @tstmps = sort { $a <=> $b } keys(%timestamps);
	foreach my $label ('entire', @labels) {
		print "tracking $label\n";
		foreach my $thread (@threads) {
			foreach my $tstmp (@tstmps) {
				if($gthreads{$thread}{'first'} <= $tstmp && $gthreads{$thread}{'last'} >= $tstmp) {
					$glabels{$label}{$tstmp, 'activethreads'} += 1;
				}
			}
		}
	}
}

#---
# charts will be created
# if something could be parsed
#---
if($respcount > 0) {
	#---
	# number of time stamps
	#---
	$measures = scalar(keys(%timestamps));

	print "Generating stacked bars absolute\n" if $DEBUG;
	&ChartStackedBars();

	print "Generating stacked bars relative\n" if $DEBUG;
	&ChartStackedPct();
	
	foreach my $label ('entire', @labels) {
		if($entireby > 0) {
			&ChartLines($label, 'throughput');
		}
		&ChartLines($label, 'users');
	}
}
#-------------------------------------------------------------------------------
sub ChartStackedPct {

	if(scalar(@labels) == 0) {
		return undef;
	}

	my $ChartStacked = Chart::StackedBars->new(1024, 768);

	#---
	# cusps
	#---
	my @xaxis = ();
	my @xlabels = ();
	foreach my $label (@labels) {
		print "Attempting to add $label to StackedPCT graph\n" if $DEBUG;
		if(($glabels{$label}{'respcount'} > ($respcount / 100)) || grep(/-alllb/i, @args)) {
			push(@xaxis, $label);
                        if (length $label > 25) {
                            $label = substr($label,0,25) . " " . substr($label,25);
                        }
			push(@xlabels, $label);
			print " Added $label\n" if $DEBUG;
		}
	}
	$ChartStacked->add_dataset(@xlabels);

	my ($value,$i,$label);
	my @data = ();
	my @legend_labels = ();

	for($i = 0; $i <= $#cusps; $i++) {
		@data = ();
		foreach my $label (@xaxis) {
			$value = $glabels{$label}{$cusps[$i]};
			if(!defined $value) {
				$value = 0;
			}
			$value = (100 * $value) / $glabels{$label}{'respcount'};
			push(@data, $value);
		}
		$ChartStacked->add_dataset(@data);

		push(@legend_labels, "< " . $cusps[$i] . " msec");
	}

	my %settings = (
		transparent => 'true',
		title => 'Response Time %',
		y_grid_lines => 'true',
		legend => 'right',
		legend_labels => \@legend_labels,
		precision => 0,
		y_label => 'Requests %',
		max_val => 100,
		include_zero => 'true',
		point => 0,
		colors => \%colors,
		x_ticks => 'vertical',
		precision => 0,
	);

	$ChartStacked->set(%settings);

	print "Generated ChartStackedPct.png\n" if $DEBUG;
	$ChartStacked->png("ChartStackedPct.png");
}
#-------------------------------------------------------------------------------
sub ChartStackedBars {

	if(scalar(@labels) == 0) {
		return undef;
	}

	my $ChartStacked = Chart::StackedBars->new(1024, 768);

	#---
	# cusps
	#---
	my @xaxis = ();
	my @xlabels = ();
	foreach my $label (@labels) {
		print "Added $label to StackedPCT graph\n" if $DEBUG;
		if(($glabels{$label}{'respcount'} > ($respcount / 100)) || grep(/-alllb/i, @args)) {
			push(@xaxis, $label);
                        push(@xlabels, $label);
		}
	}
	$ChartStacked->add_dataset(@xlabels);

	my ($value,$i,$label);
	my @data = ();
	my @legend_labels = ();
	for($i = 0; $i <= $#cusps; $i++) {
		@data = ();
		foreach my $label (@xaxis) {
			$value = $glabels{$label}{$cusps[$i]};
			if($value == undef) {
				$value = 0;
			}
			push(@data, $value);
		}
		$ChartStacked->add_dataset(@data);

		push(@legend_labels, "< " . $cusps[$i] . " msec");
	}

	my %settings = (
		transparent => 'true',
		title => 'Response Time',
		y_grid_lines => 'true',
		legend => 'right',
		legend_labels => \@legend_labels,
		precision => 0,
		y_label => 'Requests',
		include_zero => 'true',
		point => 0,
		colors => \%colors,
		x_ticks => 'vertical',
		precision => 0,
	);

	$ChartStacked->set(%settings);

	print "Generating ChartStacked.png\n" if $DEBUG;
	$ChartStacked->png("ChartStacked.png");
}
#-------------------------------------------------------------------------------
sub ChartLines {
	my ($label, $mode) = @_;

	my %labelmap = (
		'entire' => 'total',
	);

	my $title = $label;
       	$title = $labelmap{$label} if($labelmap{$label});

	my $ChartComposite = Chart::Composite->new(1024, 768);

	my @tstmps = sort { $a <=> $b } keys(%timestamps);
	my @responsetimes = ();
	my @plusstddev = ();
	my @minusstddev = ();
	my @users = ();
	my @throughput = ();
	my @xaxis = ();
	my $y2label;


	#---
	# response times
	#---
	my $tstmp;
	my ($pstd, $mstd) = (0, 0);
	foreach my $tstmp (@tstmps) {
		if($glabels{$label}{$tstmp, 'avg'}) {
			push(@xaxis, $tstmp);
			push(@responsetimes, $glabels{$label}{$tstmp, 'avg'});

			$mstd = $glabels{$label}{$tstmp, 'avg'} - $glabels{$label}{$tstmp, 'stddev'};
			$pstd = $glabels{$label}{$tstmp, 'avg'} + $glabels{$label}{$tstmp, 'stddev'};
			$mstd = 1 if($mstd < 0);	# supress lines below 0
			push(@plusstddev, $pstd);
			push(@minusstddev, $mstd);
		}
	}
	$ChartComposite->add_dataset(@xaxis);
	$ChartComposite->add_dataset(@responsetimes);

	my %colors = (
		dataset0 => "green",
		dataset1 => "red",
	);
	my @ds1 = (1);
	my @ds2 = (2);
	if(grep(/-stddev/ || /-range/, @args)) {
		$ChartComposite->add_dataset(@plusstddev);
		$ChartComposite->add_dataset(@minusstddev);
		@ds1 = (1, 2, 3);
		@ds2 = (4);

		%colors = (
			dataset0 => "green",
	       		dataset1 => [189, 183, 107],	# dark khaki
	       		dataset2 => [189, 183, 107],	# dark khaki
			dataset3 => "red",
		);
	}

	if($mode eq 'users') {
		#---
		# users
		#---
		foreach my $tstmp (@xaxis) {
			push(@users, $glabels{$label}{$tstmp, 'activethreads'});
		}
	
		$ChartComposite->add_dataset(@users);
		$y2label = "active threads";
	} else {
		#---
		# throughput
		#---
		foreach my $tstmp (@xaxis) {
			push(@throughput, $glabels{$label}{$tstmp, 'throughput'});
		}
		$ChartComposite->add_dataset(@throughput);
		$y2label = "throughput bytes/min";
	}

	my $skip = 0;
	if(scalar(@xaxis) > 40) {
		$skip = int(scalar(@xaxis) / 40) + 1;
	}

	my @labels = ($label, $mode);
	if(grep(/-stddev/, @args)) {
		@labels = ($label, "+stddev", "-stddev", $mode);
	}

	my $type = 'Lines';
	if(grep(/-range/i, @args)) {
		@labels = ($label, "n.a", "n.a", $mode);
		$type = 'ErrorBars';
	}

	my %settings = (
		composite_info => [ [$type, \@ds1], ['Lines', \@ds2 ]],
		transparent => 'true',
		title => 'Response Time ' . $title,
		y_grid_lines => 'true',
		legend => 'bottom',
		y_label => 'Response Time msec',
		y_label2 => $y2label,
		legend_labels => \@labels,
		legend_example_height => 1,
		legend_example_height0 => 10,
		legend_example_height1 => 2,
		legend_example_height2 => 2,
		legend_example_height3 => 10,
		legend_example_height4 => 10,
		include_zero => 'true',
		x_ticks => 'vertical',
		skip_x_ticks => $skip,
		brush_size1 => 3,
		brush_size2 => 3,
		pt_size => 6,
		point => 0,
		line => 1,
		f_x_tick => \&formatTime,
		colors => \%colors,
		precision => 0,
	);

	$ChartComposite->set(%settings);

	my $filename = $label;
	$filename=~ s/\W/_/g;
	$filename .= '_' . $mode . '.png';
	print $filename, "\n";

	$ChartComposite->png($filename);
}
#-------------------------------------------------------------------------------
sub formatTime {
	my ($tstmp) = @_;

	my $string = scalar(localtime($tstmp));

	my ($rc) = ($string =~ /\s(\d\d:\d\d:\d\d)\s/);

	return $rc;
}
#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------

