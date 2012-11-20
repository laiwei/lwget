#!/usr/bin/perl
require 5.8.5;
use strict;
use warnings;
use threads;
use threads::shared;
use IO::File;
use IO::Socket;
use Net::FTP;
use Digest::MD5;
use POSIX qw(strftime);
use Getopt::Long;
use Data::Dumper;

my $_check_md5 = '584f447d495c3e7dd14ff3488e5b8726';
my $_check_lwget_name = $0;
my $_check_flag = '__LWGET_START__';
my $_no_check_flag = '___LWGET_END___';
my $_flag = 0;
my $_fh = new IO::File;
if( $_fh->open( "$_check_lwget_name" ) ){
	my $_actual_md5 = Digest::MD5->new;
	while(<$_fh>){
		$_flag = 1 if ($_ =~ /^$_check_flag/);
		$_flag = 0 if ($_ =~ /^$_no_check_flag/);
		$_actual_md5->add($_) if ( $_flag == 1 );
	}
	if( $_actual_md5->hexdigest ne $_check_md5){
		&write_log("$_check_lwget_name seems has been modified... and lwget exit with 201");
		&the_exit (201);
	}
	$_fh->close;
}
###------ anything below should NOT be modified ------###
__LWGET_START__:
my $g_debug = 0;
my $g_quiet = 0;
my $g_continue = 0;
my $g_block_size = '3m';
my $g_limit_rate = '25m';
my $g_thread_num = 4;
my $g_output_file = '';
my $g_md5_file = -1;
my $g_url = '';

my %g_buffer_queue:shared;
my %g_speed_queue:shared;
my $g_delay_time :shared = 0;
my %g_task_queue;
my $g_retry_times = 3;
my $g_count :shared = 0;
my $g_count_unit = 0.002;
my $EXIT :shared = 0 ; 
$SIG{TERM} = sub { $EXIT = 1 ; select (undef, undef, undef, 0.1); };
my $thr_time; #time thread tid

GetOptions(
	'd|debug+' => \$g_debug,
	'q|quiet+' => \$g_quiet,
	'c|continue+' => \$g_continue,
	'b|block-size=s' => \$g_block_size,
	's|limit-rate=s' => \$g_limit_rate,
	'o|output-file=s' => \$g_output_file,
	'n|thread-num=i' => \$g_thread_num,
	'm|md5:s' => \$g_md5_file,
	'h|help' => \&print_help,
	'v|version' => \&print_help,
	'<>' => sub{$g_url = shift;},
) || &print_help();

if( $g_url eq '' ) {
	&write_log("You Must give a url, so exit 1", "[ALERT]");
	&the_exit (1);
}

if( uc($g_block_size) =~ /^(\d+)([MK]?)/ ){
	my ($a, $b) = ( $1, uc($2) );
	if( $b eq 'M' ){
		$g_block_size = ($a * 1024 * 1024);
	}elsif( $b eq 'K' ){
		$g_block_size = ($a * 1024);
	}else{
		$g_block_size = $a;
	}
	if ( $g_block_size > 10*1024*1024 ){
		$g_block_size = 10*1024*1024;
		&write_log( "block-size should not > 10M, so change to 10M ","[NOTICE]" ) if $g_quiet == 0;
	}
	$g_block_size += 1 if $g_block_size%2 == 0;
}
if ( uc($g_limit_rate) =~ /^(\d+)([MK]?)/ ){
	my ($a, $b) = ( $1, uc($2) );
	if( $b eq 'M' ){
		$g_limit_rate = ($a * 1024 * 1024);
	}elsif( $b eq 'K' ){
		$g_limit_rate = ($a * 1024);
	}else{
		$g_limit_rate = $a;
	}
}
if ( $g_thread_num > 50 ) {
	$g_thread_num = 50;
        &write_log( "g_thread_num should not > 50, so change it to 50 ","[NOTICE]" ) if $g_quiet == 0;
}

##---- 删除url末尾存在的一个或多个"/"
$g_url =~ s#(.*?)/+$#$1#;
if ( $g_url =~ m#^(ftp|http)://(.*)$# ) {
	my $proto = $1;
	my $path = $2;
	
	$thr_time = threads->new( \&the_time, $g_count_unit ) or &the_die ( "Cannot Create Count Time Thread: $!" );
	$thr_time->detach();

	if( $proto eq 'ftp' ){
		&do_ftp( $path );
	}else{
		&do_http( $path );
	}
	$EXIT = 1;
	select (undef, undef, undef, $g_count_unit*3);
} else {
	&write_log("We only sopourt 'FTP' and 'HTTP', so exit 2", "[ALERT]");
	&the_exit (2);
}

sub do_ftp {
	my $fullpath = shift;
	my $ftp_user = 'anonymous';
	my $ftp_pass = 'anonymous';
	my $ftp_host = '';
	my $ftp_port = 21;
	my $ftp_path = '/';
	my $ftp_file = '';

	my $file_haveread = 0;

	my ($a, $b);
	if ( $fullpath =~ /\@/ ){
		if( $fullpath =~ /^(.+)\@([^\@]+)$/ ){
			$a = $1;
			$b = $2;
		}else{
			$a = undef;
		}
	}
	if( defined $a ){
		if( $a =~ m#^(.+):(.+)$# ){
			$ftp_user = $1;
			$ftp_pass = $2;
			$fullpath = $b;
		}else {
			&write_log( "the URL input is invalid, so exit 3", "[ALERT]" );
			&the_exit (3);
		}
	}
	$fullpath =~ s#/+#/#g;
	if( $fullpath =~ m#^([^/]+?)(?::([0-9]+))?/((?:[^/]+/)*)([^/]+)$# ){
		$ftp_host = $1;
		$ftp_port = $2 if defined $2;
		$ftp_path .= $3 if defined $3;
		$ftp_file = $4;
	}
	$g_output_file = $ftp_file if $g_output_file eq '';
	$g_md5_file = $g_output_file.".md5" if $g_md5_file eq '';
	if( $g_continue > 0 && -s $g_output_file ){
		$file_haveread = (stat($g_output_file))[7];
	}
	
	if( $g_quiet == 0 ) {
	print <<__END;
	---------------------------------------
	*  debug = $g_debug
	*  quiet = $g_quiet
	*  continue = $g_continue
	*  block-size = $g_block_size
	*  maxspeed = $g_limit_rate
	*  thread-num = $g_thread_num
	*  ftp_host = $ftp_host
	*  ftp_port = $ftp_port
	*  ftp_path = $ftp_path
	*  ftp_file = $ftp_file
	*  output_file = $g_output_file
	*  md5_file = $g_md5_file
	----------------------------------------
__END
	}
	###-------- Begin FTP download ----------------###
	my $ftp_file_size;
	my $block_num;

	my $ftp = Net::FTP->new( $ftp_host, Debug => $g_debug, Port => $ftp_port) 
		or &the_die( "Cannot connect to $ftp_host: $@" );
	$ftp->login( $ftp_user, $ftp_pass ) or &the_die( "Cannot login ", $ftp->message );
	$ftp->cwd( $ftp_path ) or &the_die( "Cannot cwd ", $ftp->message );
	$ftp->binary() or &the_die( "Cannot change to BINARY mode ", $ftp->message );
	$ftp_file_size = $ftp->size( $ftp_file );
	if( !defined $ftp_file_size || $ftp_file_size < 0 ) {
		&the_die( "Cannot get the remote file size: ", $ftp->message );
	}
	&write_log( "$ftp_file file size = $ftp_file_size", "[NOTICE]" ) if $g_quiet == 0; 
	
	if( ! $ftp->supported('REST') ){
		$g_thread_num = 1;
		$file_haveread = 0;	#file_haveread is 0, represent DO NOT continue transfer
		&write_log("Not support REST, so not support multi-threads and continue transfer", "[NOTICE]");
	}
	$ftp->quit();

	###----- 分配下载任务,构造下载任务队列 -----###
	###----- block_num记录了远程文件被分解为多少个block,每个block的大小为block_size
	$ftp_file_size -= $file_haveread; #--for continue transfer
	&write_log( "here $ftp_file_size to be left ", "[NOTICE]" ) if $g_quiet == 0;
	$block_num =  int ( $ftp_file_size / $g_block_size );
	$block_num++ if( $ftp_file_size % $g_block_size != 0 );
	&write_log( "$ftp_file divide to $block_num BLOCKS", "[NOTICE]" ) if $g_quiet ==0;

	my $block_id = 1;
	my $thr_id;
	while( $block_id <= $block_num ) {
		for ( $thr_id = 1; $thr_id <= $g_thread_num; $thr_id ++ ) {
			my $begin = ($block_id - 1) * $g_block_size;
			my $size = $g_block_size;
			if( $block_id == $block_num ){
				$size = $ftp_file_size - ( $g_block_size * ($block_id-1) );
			}
			push ( @{ $g_task_queue{$thr_id}->{$block_id} }, $begin, $size );
			$block_id++;
			last if $block_id > $block_num; #-- important here
		}
	}
	
	###----- 创建下载线程 处理下载任务 
	my @thr_list = ();
	my %thr_arg;
	$thr_arg{'ftp_host'} = $ftp_host;
	$thr_arg{'ftp_user'} = $ftp_user;
	$thr_arg{'ftp_pass'} = $ftp_pass;
	$thr_arg{'ftp_port'} = $ftp_port;
	$thr_arg{'ftp_path'} = $ftp_path;
	$thr_arg{'ftp_file'} = $ftp_file;
	$thr_arg{'file_haveread'} = $file_haveread;
	
	foreach my $thr_num ( sort keys %g_task_queue ){
		$g_debug == 0 or print "the thread : $thr_num\n";
		$thr_arg{'connection'} = $thr_num;
		my ($tmp_id) = threads->new( \&do_ftp_thread, $g_task_queue{$thr_num}, \%thr_arg );
		push @thr_list, $tmp_id;
		$tmp_id->detach();
	}
	
	###------ 下载从缓冲区写入文件 计算md5
	my $_arg;
	$_arg->{'block_num'} = $block_num;
	$_arg->{'file_haveread'} = $file_haveread;
	$_arg->{'file_size'} = $ftp_file_size;
	$_arg->{'block_size'} = $g_block_size;
	&gen_md5_write_file($_arg);

}

###----- 下载子线程函数 处理下载队列中的任务
###----- input -> 任务队列 task_queue{$thr_id}
sub do_ftp_thread {
	my $thr_task_queue = shift;
	my $thr_arg = shift;
	my ($start_t, $end_t, $offset_t);
		
	foreach my $block_id ( sort{$a <=> $b} keys %{ $thr_task_queue } ){
		my $begin = $thr_task_queue->{$block_id}->[0];
		my $size = $thr_task_queue->{$block_id}->[1];
		$g_debug > 0 and
		print "connection $thr_arg->{'connection'}-----block: $block_id ---- begin:$begin ---- size:$size\n";
		
		$start_t = $g_count; 
		my $thr_ftp = Net::FTP->new( $thr_arg->{'ftp_host'}, BlockSize =>102400, Debug => $g_debug, 
			Port=>$thr_arg->{'ftp_port'} ) or &the_die( "Cannot connect to $thr_arg->{'ftp_host'}: $!" );
		$thr_ftp->login( $thr_arg->{'ftp_user'},$thr_arg->{'ftp_pass'} ) 
			or &the_die( "Cannot login ", $thr_ftp->message );
		$thr_ftp->cwd( $thr_arg->{'ftp_path'} ) 
			or &the_die( "Cannot cwd ", $thr_ftp->message );
		$thr_ftp->binary() 
			or &the_die( "Cannot change to BINARY mode ", $thr_ftp->message );
	
		#--- start download file from $begin
		$thr_ftp->restart( $begin + $thr_arg->{'file_haveread'} ); #-- important, support continue transfer
		my $thr_data = $thr_ftp->retr($thr_arg->{'ftp_file'}) 
			or print $thr_ftp->message;
		my ($thr_buf, $cur_have_read) = ('', 0);
		my $tmp_buf;
		while ( $cur_have_read < $size ){
			my $read_left = $size - $cur_have_read;
			if( my $len = $thr_data->read( $thr_buf, $read_left ) ){
				$cur_have_read += $len;
				$tmp_buf .= $thr_buf;
			}
			select (undef, undef, undef, $g_delay_time );
		}
		$end_t = $g_count;
		$offset_t = ( $end_t - $start_t + $g_count_unit ) * $g_count_unit;
		$offset_t = $g_count_unit/2  if $offset_t == 0;
		$g_speed_queue{$block_id} = $size/$offset_t;
		$g_buffer_queue{$block_id} = $tmp_buf;
		$thr_ftp->close;
		$thr_data->close;
	}	
}

sub do_http {
        my $fullpath = shift;
        my $http_host = '';
        my $http_path = '/';
        my $http_file = '';
	my $http_port;

        my $file_haveread = 0;
        
	$fullpath =~ s#/+#/#g;
        if( $fullpath =~ m#^([^/]+?)(?::([0-9]+))?/((?:[^/]+/)*)([^/]+)$# ){
                $http_host = $1;
		$http_port = $2 || 80;
                $http_path .= $3 if defined $3;
                $http_file = $4;
        }
	$g_output_file = $http_file if $g_output_file eq '';
        $g_md5_file = $g_output_file.".md5" if $g_md5_file eq '';
	$http_file = $http_path.$http_file;
        if( $g_continue > 0 && -s $g_output_file ){
                $file_haveread = (stat($g_output_file))[7];
        }

	if( $g_quiet == 0 ) {
		print <<__END;
		---------------------------------------
		*	debug = $g_debug
		*	quiet = $g_quiet
		*	continue = $g_continue
		*	block-size = $g_block_size
		*	maxspeed = $g_limit_rate
		*	thread-num = $g_thread_num
		*	output-file = $g_output_file
		*	md5_file = $g_md5_file
                *
		*	http_host = $http_host
		*	http_port = $http_port
		*	http_path = $http_path
		*	http_file = $http_file
		----------------------------------------
__END
	}
	
	###-------- Begin HTTP download ----------------###
	my $http_file_size;
	my $block_num;
	####---------------------- Get file size 
	my $s = IO::Socket::INET->new(PeerAddr => $http_host,
			PeerPort => $http_port,
			Proto => "tcp",
			Type => SOCK_STREAM) or &the_die( "Cannot connect: $!" );
	print $s "HEAD $http_file HTTP/1.0\n";
	print $s "Host: $http_host\n";
	print $s "Connection: close\n\n";
	if( <$s> =~ m!HTTP/1\.[01] 200 OK! ){
		while (<$s>){
			last if m!^Content-Length:\s*(\d+)! and $http_file_size=$1;
		}
	}else {
		print "Failed Get $http_file size\n";
	}
	close $s;
	unless( defined $http_file_size ){
		print "Get $http_file size failed, and exit with 101\n";
		&the_exit (101);
	}
	&write_log( "$http_file total size is $http_file_size", "[NOTICE]" );

	####--------------------- Test if the server support RESUME
	$s = IO::Socket::INET->new(PeerAddr => $http_host,
			PeerPort => $http_port,
			Proto => "tcp",
			Type => SOCK_STREAM) or &the_die( "Cannot connect: $!" );
	print $s "HEAD $http_file HTTP/1.0\n";
	print $s "Host: $http_host\n";
	print $s "Range: bytes=0-$http_file_size\n";
	print $s "Connection: close\n\n";
	if( <$s> !~ m!^HTTP/1\.[01] 206 Partial Content! ){
		print $http_host,' Resume Not Supported',"\n";
		$g_thread_num = 1;
		$g_continue = 0;
		$file_haveread = 0;
	}
	close $s;

	###----- 分配下载任务,构造下载任务队列 -----###
	###----- block_num记录了远程文件被分解为多少个block,每个block的大小为block_size
	$http_file_size -= $file_haveread; #--for continue transfer
		&write_log( "here $http_file_size to be left ", "[NOTICE]" ) if $g_quiet == 0;
	$block_num =  int ( $http_file_size / $g_block_size );
	$block_num++ if( $http_file_size % $g_block_size != 0 );
	&write_log( "$http_file divide to $block_num BLOCKS", "[NOTICE]" ) if $g_quiet ==0;

	my $block_id = 1;
	my $thr_id;
	while( $block_id <= $block_num ) {
		for ( $thr_id = 1; $thr_id <= $g_thread_num; $thr_id ++ ) {
			my $begin = ($block_id - 1) * $g_block_size;
			my $size = $g_block_size;
			if( $block_id == $block_num ){
				$size = $http_file_size - ( $g_block_size * ($block_id-1) );
			}
			push ( @{ $g_task_queue{$thr_id}->{$block_id} }, $begin, $size );
			$block_id++;
			last if $block_id > $block_num; #-- important here
		}
	}
	#print Dumper(\%g_task_queue);
	
	###----- 创建下载线程 处理下载任务 
	my @thr_list = ();
	my %thr_arg;
	$thr_arg{'http_host'} = $http_host;
	$thr_arg{'http_port'} = $http_port;
	$thr_arg{'http_file'} = $http_file;
	$thr_arg{'file_haveread'} = $file_haveread;

	foreach my $thr_num ( sort keys %g_task_queue ){
		$g_debug ==0 or print "the thread : $thr_num\n";
		$thr_arg{'connection'} = $thr_num;
		my ($tmp_id) = threads->new( \&do_http_thread, $g_task_queue{$thr_num}, \%thr_arg );
		push @thr_list, $tmp_id;
		$tmp_id->detach();
	}
		
	###-----计算md5 and write contents from buffer to localfile
	my $_arg;
	$_arg->{'block_num'} = $block_num;
	$_arg->{'file_haveread'} = $file_haveread;
	$_arg->{'file_size'} = $http_file_size;
	$_arg->{'block_size'} = $g_block_size;
	&gen_md5_write_file($_arg);
}

###---- function to generate md5 and write buffer to local file
sub gen_md5_write_file{
	my $_arg = shift;
        my $digest;
        my $md5 = Digest::MD5->new;
	
	my $fh = new IO::File;
        $fh->open( ">$g_output_file" ) || &the_die( "$!" ) if $g_continue == 0 ;
        $fh->open( ">>$g_output_file" )|| &the_die( "$!" ) if $g_continue > 0 ;
	binmode($fh);
        my $sleep_t = $g_count_unit;
        my $today_total_read = 0;
        my $total_read = $_arg->{'file_haveread'};

        $| = 1;
	
	my $is_busy_channel = 1; #默认处于低速网络中
	for (my $i = 1; $i<= $_arg->{'block_num'}; $i++ ){
        	my $speed = 0;
                while( ! defined $g_buffer_queue{$i} ){
                        select(undef,undef,undef,$sleep_t);
                }
                $total_read += $_arg->{'block_size'};
                $today_total_read += $_arg->{'block_size'};

                print $fh $g_buffer_queue{$i};
                ###--- 不续传 并且 指定了md5, 才生成md5
                $md5->add( $g_buffer_queue{$i} ) if $g_md5_file ne '-1' && $g_continue == 0;
                delete $g_buffer_queue{$i};
                
		###--- 计算speed
		for( my $j = 0; $j < $g_thread_num; $j++){
			defined $g_speed_queue{$i-$j} and $speed += $g_speed_queue{$i-$j};
		}
		$g_debug == 0 or
		&write_log("bockid = $i total_read = $total_read $speed > $g_limit_rate",
			"[NOTICE]");
		my $factor = 10;
		my $adjust = 0;
		if( $speed > $g_limit_rate ) {
			$adjust == 1 or $g_delay_time += $g_count_unit;
			$is_busy_channel = 0;
		}else{
			$adjust = 1;
			if ( $is_busy_channel == 1 ) {
				$g_delay_time = 0;
			}else{
				$g_delay_time -= $g_count_unit;	
			}
		}

		if( $g_quiet == 0 ){
			my ($a,$b,$c,$d,$s);
			$c = $_arg->{'file_size'} + $_arg->{'file_haveread'};
			
			if( $speed <= 1048576 ) {
				$s = sprintf("%10.2fK/s", $speed/1024 );
			}else {
				$s = sprintf("%10.2fM/s", $speed/1048576 );
			}

			if($total_read <= 1048576){
				$a = sprintf("%10.2fK", $total_read/1024 );
			}else{
				$a = sprintf("%10.2fM", $total_read/1048576 );
			}

			$b = sprintf( "%10.2f%%", $total_read / $c *100 );
			$d = int( ($c - $total_read)/$speed ) if $speed != 0;
			$d = sprintf( "%10ds", $d);
			my $t = &get_log_date();
			$t = sprintf( "%-25s", $t );
			print "\r$t............................$a $b $s $d";
			$g_debug == 0 or print "\n";
		}
		$today_total_read = 0;
        }
	print "\n";
	$fh->close();
        if( $g_md5_file ne '-1' && $g_continue == 0 ){
		my $fm = new IO::File;
                if( $fm->open( ">$g_md5_file" ) ) {
                        print "\n";
                        &write_log( "---begin digest ", "[NOTICE]" );
                        $digest = $md5->hexdigest;
                        print $fm "$digest  $g_output_file\n";
                        print "$digest  $g_output_file\n";
                        $fm->close; 
			&write_log( "---end digest ", "[NOTICE]" );
                }else{
                        &write_log( "open md5file failed, so exit 4 ", "[ALERT]" );
                        &the_exit (4);
                }
        }
}
sub do_http_thread{
	my $thr_task_queue = shift;
	my $thr_arg = shift;
	my ($start_t, $end_t, $offset_t);

	foreach my $block_id ( sort{$a <=> $b} keys %{ $thr_task_queue } ){
		my $_retry_time = 0;
 		$start_t = $g_count; 
	RETRY_AGAIN:
		$_retry_time ++;
		my $begin = $thr_task_queue->{$block_id}->[0] + $thr_arg->{'file_haveread'};
		my $size = $thr_task_queue->{$block_id}->[1] + $begin - 1;
		my $http_range = "$begin-$size";
		$g_debug > 0 and
		print "connection $thr_arg->{'connection'}----block: $block_id ---- range:$http_range\n";
		
		my $s = IO::Socket::INET->new(PeerAddr => $thr_arg->{'http_host'},
			PeerPort => $thr_arg->{'http_port'},
			Proto => "tcp",
			Type => SOCK_STREAM) or &the_die( "Cannot connect: $!" );
		print $s "GET $thr_arg->{'http_file'} HTTP/1.0\n";
		print $s "Host: $thr_arg->{'http_host'}\n";
		print $s "Range: bytes=$http_range\n";
		print $s "Connection: close\n\n";
		unless( <$s> =~ m!HTTP/1\.[01] 206 Partial Content! ) {
			close($s); 
			if($_retry_time < $g_retry_times){
				chomp $_; print "Failed [$_] \n";
				print "Invalid URL/Unrecognized Reply/Resume Not Supported and retry $_retry_time\n";
				goto RETRY_AGAIN;
			}else{
				chomp $_;  print "Failed [$_] \n";
				print "Invalid URL/Unrecognized Reply/Resume Not Supported and exit 102\n";
				&the_exit(102);
			}
		}
		while( (my $mime = <$s>) =~ m!\w+: ! ){
			if ($mime =~ /Content-Length:\s*([0-9]+)/) { 
				my $_total = $1; 
				$g_debug >0 and print 'Content-Length: ', $_total, ' ';
			}
			if( $mime =~ m!Content-Range:\s*bytes\s*(\d+)-(\d+)/(\d+)!){
				my ($_start,$_finish,$_filesize) = ($1, $2, $3);
				$g_debug >0 and print $mime;
			}
		}
		my ( $_buf, $_len ) = ('', 0);
		while (<$s>){
			$_buf .= $_;
			$_len += length($_);	
		}
		close $s;
		select (undef, undef, undef, $g_delay_time*2 );
		$end_t = $g_count;
		$offset_t = ( $end_t - $start_t ) * $g_count_unit;
		$offset_t = $g_count_unit/2  if $offset_t == 0;
		$g_speed_queue{$block_id} = ($size- $begin)/$offset_t;
		$g_buffer_queue{$block_id} = $_buf;
	}

}
sub write_log{
	my $msg = shift;
	my $log_type = shift || '[NOTICE] ';
	my $log_file = shift;
	chomp $msg;
	$msg = $log_type . &get_log_date(). " $msg\n"; 
	if( defined $log_file ){
		if( ! open(my $log_fh, ">>$log_file") ){
			warn "open log file $log_file fail: $!";
			print STDOUT $msg;
		}else{
			print $log_fh $msg;
		}
	}else {
		print STDOUT "$msg";
	}
}
sub get_log_date {
	my $date = strftime "%F %T", localtime(time);
	$date = localtime if $date eq ' ';
	$date = "[$date]" ; 
	return scalar $date ;
}

sub the_time{
	my $unit = shift || 0.001;
	while ( ! $EXIT ){
		select(undef,undef,undef,$unit);
		$g_count ++;
	}
}

sub the_exit{
	my $stat = shift || 0;
	$EXIT = 1;
	select(undef,undef,undef,0.1);
	exit $stat;
}
sub the_die{
	$EXIT = 1;
        select(undef,undef,undef,0.1);
	print @_, "\n";
	exit -1;
}

sub print_help {
	print <<__EOF;
--------------------------------------------------------------------------------------------------
Usage: lwget--- multi-threads download tool, surport md5 
	-d|--debug			: print FTP and HTTP message, default No message
	-c|--continue			: resume getting a partially-downloaded file
	-b|--block-size=3m  		: data to be devided, each size is "blocksize", default 3M
	-s|--limit-rate=25m  		: max speed, dufault 25M/s
	-o|--output-file=foo 		: local file name, dufalut same to remote file
	-n|--thread-num=4 		: threadnum, default 4, and recommended <= 16
	-m|--md5=foo.md5		: generate md5 file 
	-q|--quiet			: quiet (no output)
	-h|--help 			: dispaly this message
	-v|--version    		: 1.0.0.1, laiwei\@baidu.com 20091225
--------------------------------------------------------------------------------------------------	
__EOF
	exit 100;
}
___LWGET_END___:
###------ anything beyond should NOT been modified and End here------###
