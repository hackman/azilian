#!/usr/bin/perl
use strict;
use warnings;
use Linux::Unshare qw(unshare CLONE_CONTAINER);
use BSD::Resource;

our $LOG;

sub logger {
	print $LOG strftime('%b %d %H:%M:%S', localtime(time)) . ' ' . $_[0] ."\n";
}

sub get_current_cgroup_settings {
	my $conf_ref = $_[0];
	my $resources = {
		'cpus' => 0,
		'mems' => 0,
		'memory' => 1024000000,
		'procs' => 5000
	};
	# Default limits:
	# 1 core
	# 1 physical memory bank
	# 1024MB RAM
	# 5000 procs
	open my $CPU, '<', "$conf_ref->{'cgroup_base'}/cpuset.cpus";
	$$resources{'cpus'} = <$CPU>;
	close $CPU;

	open my $MEM, '<', "$conf_ref->{'cgroup_base'}/cpuset.cpus";
	$$resources{'mems'} = <$CPU>;
	close $MEM;

	return \$resources;
}

# Accepts a file name and a string to write into the file
sub write_to_cgroup {
	my $file = $_[0];
	my $string = $_[1];
	if ( ! -f $file ) {
		logger "the resource file $file is missing";
		return 0;
	}
	open my $F, '>', $file;
	if ($! != 0) {
		logger "unable to open $file";
		return 0;
	}
	print $F $string;
	close $F;
}

sub cleanup_cgroup {
	my $conf_ref = $_[0];
	my $name = $_[1];
	my $stage = $_[2];
	my $container_cgroup_dir = "$conf_ref->{'cgroup_base'}/$name";
	if ($stage >= 0) {
		rmdir($container_cgroup_dir);
		exit 2;
	}
	if ($stage >= 1) {
		
	}
}

sub setup_cgroup {
	my $conf_ref = $_[0];
	my $name = $_[1];
	my $res_ref;
	my $container_dir = "$conf_ref->{'cgroup_base'}/$name/";
	my $ret;

	$res_ref = get_current_resources($conf_ref);

	if (! -d $container_dir && !mkdir($container_dir)) {
		logger "unable to create cgroup for container $name";
		exit 2;
	}

	$ret = write_to_cgroup("$container_dir/cpuset.cpus", $res_ref->{'cpus'});
	cleanup_cgroup($conf_ref, $name, 0) if !$ret;

	$ret = write_to_cgroup("$container_dir/cpuset.mems", $res_ref->{'mems'});
	cleanup_cgroup($conf_ref, $name, 0) if !$ret;

	$ret = write_to_cgroup("$container_dir/cpu.cfs_quota_us", $conf_ref->{'limits'}->{'cpu_quota'});
	cleanup_cgroup($conf_ref, $name, 0) if !$ret;

	$ret = write_to_cgroup("$container_dir/cpu.cfs_period_us", $conf_ref->{'limits'}->{'cpu_period'});
	cleanup_cgroup($conf_ref, $name, 0) if !$ret;

	$ret = write_to_cgroup("$container_dir/memory.limit_in_bytes", $conf_ref->{'limits'}->{'memory'});
	cleanup_cgroup($conf_ref, $name, 0) if !$ret;

	$ret = write_to_cgroup("$container_dir/cpuacct.tasks_limit", $conf_ref->{'limits'}->{'procs'});
	cleanup_cgroup($conf_ref, $name, 0) if !$ret;
}

sub close_fds {
	# Find the maxfd limit first
	my $maxfd = getrlimit( RLIMIT_NOFILE );
	no warnings;
	for (my $i = 0; $i < $maxfd; $i++ ) {
		close $i;
	}
	use warnings;
}

sub setup_namespaces {
	my $conf_ref = $_[0];
	my $name = $_[1];

#	unshare(CLONE_FILES|CLONE_FS|CLONE_NEWIPC|CLONE_NEWNET|CLONE_NEWNS|CLONE_NEWUTS|CLONE_SYSVSEM|CLONE_NEWUSER);
	unshare(CLONE_CONTAINER);
	chdir('/');
	return;
}

sub drop_capabilities {
	# Should use Linux::capabilities when it is uploaded
	return;
}

sub init_container {
	my $conf_ref = $_[0];
	my $name = $_[1];
	my $pid = fork();
	if ($pid == 0) {
		close $LOG;
		close_fds();
		$ENV{'PATH'} = '/sbin:/bin:/usr/sbin:/usr/bin';
		exec('init') or print STDERR "Unable to execute init for container $name: $!";
#		exec('init') or {
#			print STDERR "Unable to execute init for container $name: $!";
#			exit 1;
#		};
	} else {
		helpers($conf_ref, 'post_init', $name);
		return;
	}
}

sub helpers {
	my $conf_ref = $_[0];
	my $dir_name = $_[1];
	my $name = $_[2];
	my $scripts_dir;

	if (!defined($name)) {
		logger 'Error: helpers - no container name supplied';
	}

	if (defined($conf_ref)) {
		$scripts_dir = "$conf_ref->{'helpers_dir'}/$dir_name";
	} else {
		$scripts_dir = "/etc/azilian/$dir_name";
	}

	if (! -d $scripts_dir) {
		logger "Unable to find helpers dir for $dir_name for container $name";
	}
	# Race condition here... test before use. Maybe it would be better to handle errors of opendir directly.
	opendir(my $D, $scripts_dir);
	while(readdir $D) {
		my $file = $_;
		next if ($file =~ /^\./);
		# TODO: add error handling here
		system("$conf_ref->{'helpers_dir'}/$dir_name/$file $name");
	}
	closedir($D);
}
