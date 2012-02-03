#!/usr/bin/perl -w

# Copyright (c) 2010 Ilmari Karonen <vyznev@toolserver.org>.
#
# Permission to use, copy, modify, and/or distribute this
# software for any purpose with or without fee is hereby granted,
# provided that the above copyright notice and this permission
# notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL
# WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL
# THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR
# CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
# LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT,
# NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
# CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

use utf8;
use strict;
use LWP::UserAgent;
use HTTP::Request::Common qw'POST $DYNAMIC_FILE_UPLOAD';
$DYNAMIC_FILE_UPLOAD = 1;
use XML::Simple;
use Data::Dumper 'Dumper';
use Getopt::Long 'GetOptions';
use Term::ReadKey 'ReadMode';
use POSIX 'strftime';
use Digest::SHA1;
use Time::HiRes qw'time sleep';
 
# Work with Unicode strings throughout:
binmode $_, ":utf8" for \*STDIN, \*STDOUT, \*STDERR;
utf8::decode($_) for @ARGV;
 
# Test string for LWP Unicode handling -- if this comes back mangled, abort:
my $unicode = "Üñıç∅∂\x{3F5}";
 
# Default options:
my $username = "DieBucheBot";
my $server = "commons.wikimedia.org";
my $prefix = $ENV{TMPDIR} || $ENV{TEMP} || "/tmp";
my $filelist;
my $watch;
my $confirm;
my $pngout;
my $delay = 1;
 
# Usage instructions:
my $usage = <<"USAGE";
Usage: $0 [options] <file(s)>
Options:
	-u, --user, --username=<name>
		User name to log in as (default: $username).
	-s, --server=<hostname>
		Hostname of wiki server (default: $server).
	-f, --filelist=<file>
		File to read file names from.
	-p, --prefix=<path>
		Path to save temporary files under (default: $prefix).
	-w, --watch
		Automatically add files to watchlist.
	-c, --confirm
		Prompt for confirmation before each upload.
	-d, --delay=<seconds>
		How many seconds to sleep between uploads (default: $delay).
	--pngout=<cmd>
		Command to optimize PNG files before reupload.
USAGE
# '
 
# Parse options, print usage message if failed:
GetOptions('username|u=s' => \$username,
		'server|s=s' => \$server,
		'filelist|f=s' => \$filelist,
		'prefix|p=s' => \$prefix,
		'watch|w' => \$watch,
		'confirm|c' => \$confirm,
		'delay|d=i' => \$delay,
		'pngout=s' => \$pngout,
		) and ($filelist || @ARGV) or die $usage;
 
# Read extra file names:
if ($filelist) {
	open LIST, '<:utf8', $filelist or die "Error opening $filelist: $!\n";
	push @ARGV, <LIST>;
	close LIST or die "Error closing $filelist: $!\n";
}
 
# Set up user agent:
my $ua = LWP::UserAgent->new(
					agent => "Mozilla/4.0 (compatible; $0)",
					from => $username,
					cookie_jar => {},
					parse_head => 0,
					);
 
# General purpose routine for making MediaWiki API requests:
my $apiURI = "http://$server/w/api.php";
sub apireq {
	my $query = [format => 'xml', @_];
	my $sleep = 1;
	ref($_) or utf8::encode($_) for @$query;
	ref($_) and utf8::encode($_->[0]) for @$query;
	while (1) {
	my $res = $ua->post($apiURI, $query, Content_Type => 'form-data');
	my $err = $res->header('MediaWiki-API-Error') || "";
 
	return XMLin( $res->decoded_content() ) if $res->is_success and $err ne 'maxlag';
 
	print STDERR "API request failed, ", ($err || $res->status_line), "...";
	if ($sleep > 3*60*60) {
		warn "giving up\n";
		return XMLin( $res->content );
	}
	warn "sleeping $sleep seconds\n";
	sleep $sleep;
	$sleep *= 2;
	}
}
 
# Read password from stdin and log in:
ReadMode 'noecho';
print STDERR "Password for $username \@ $server: ";
my $pass = <STDIN>;
chomp $pass;
print STDERR "\n";
ReadMode 'restore';
 
warn "Logging in to $server as $username...\n";
my $login = apireq( action => 'login', lgname => $username, lgpassword => $pass );
$login = apireq( action => 'login', lgname => $username, lgpassword => $pass, lgtoken => $login->{login}{token} )
	if ($login->{login}{result} || '') eq 'NeedToken';
$login->{error} and die "Login as $username failed ($login->{error}{code}): $login->{error}{info}\n";
$login->{login}{result} eq 'Success' or die "Login as $username failed: $login->{login}{result}\n";
 
# Do the uploads:
 
my $lasttime = time;
FILE: foreach my $title (@ARGV) {
	# Normalize filename to MediaWiki DB key form:
	s/[\s_]+/_/g, s/^_//, s/_$// for $title;
	$title = ucfirst $title;
 
	warn "Loading info for $title...\n";
 
	# Load file info and edit/upload token via API:
	my $starttime = time;
	my $data = apireq(
			maxlag => 50,
			action => 'query',
			prop => 'info|imageinfo|revisions',
			intoken => 'edit',
			iiprop => 'url|mime|size|sha1|comment|user|timestamp',
			iilimit => 50,
			rvprop => 'content|timestamp',
			rvlimit => 1,
			titles => "File:$title",
			redirects => 1,
			requestid => $unicode,
			);
	#$contents1 = $response1->
	$data->{requestid} eq $unicode
	or die "Unicode round trip failed: expected \"$unicode\", got \"$data->{requestid}\".\n";
	exists $data->{query}{pages}{page}{missing}
	and warn "Skipping $title, file does not exist.\n" and next;
	my $token = $data->{query}{pages}{page}{edittoken}
	or die "Failed to get token, got:\n", Dumper($data), "\n";
	my $text = $data->{query}{pages}{page}{revisions}{rev}{content}
	or die "Failed to get page text, got:\n", Dumper($data), "\n";
	my $timestamp = $data->{query}{pages}{page}{revisions}{rev}{timestamp}
	or die "Failed to get timestamp, got:\n", Dumper($data), "\n";
 
	my $imageinfo = $data->{query}{pages}{page}{imageinfo}{ii}
	or die "Failed to get image info, got:\n", Dumper($data), "\n";
	$imageinfo = [$imageinfo] unless ref $imageinfo eq 'ARRAY';
 
	my $url = $imageinfo->[0]{url}
	or die "Failed to get file URL, got:\n", Dumper($data), "\n";
	my $size = $imageinfo->[0]{size}
	or die "Failed to get file size, got:\n", Dumper($data), "\n";
	#$imageinfo->[0]{mime} eq 'image/svg+xml'
	#or warn "Skipping $title due to unexpected MIME type \"$imageinfo->[0]{mime}\".\n" and next;
 
	# We might get a different filename back from the API; if so, use it:
	my $curtitle = $data->{query}{pages}{page}{title}
	or die "Failed to get normalized title, got:\n", Dumper($data), "\n";
	s/^[^:]*://, tr/ /_/ for $curtitle;
 
	warn "$title normalized/redirected to $curtitle.\n" if $title ne $curtitle;
	$title = $curtitle;
 
	# If suffix isn't .png or .jpe?g, rename to force PNG format:
	#$title =~ s/\.[^.]*$/.png/ or die unless $title =~ /\.(jpe?g|png)$/i;
  
	# Local names of converted and unconverted files:
	my $file = "$prefix/$title" . "2.svg";
	my $oldfile = "$prefix/$curtitle";
 
	# If neither file exists, download the BMP first:
	unless (-e $file or -e $oldfile) {
	print STDERR "Downloading $title ($size bytes, $imageinfo->[0]{mime}) from $url to $oldfile... ";
 
	my $dl = $ua->get($url, ':content_file' => $oldfile);
	die "FAILED: " . $dl->status_line . "\n" unless $dl->is_success;
	warn $dl->status_line . "\n";
	}
 
	# If only the BMP file exists, convert it:
	unless (-e $file) {
 
	# Run ImageMagick convert command:
	warn "Converting $oldfile to $file...\n";
	system 'python','scour/scour.py', '-i', $oldfile, '-o', $file
		and next FILE;
 
	}
 
	# Show info for converted and unconverted files for comparison:
	system 'identify', $_ and die "identify failed with status $?: $!\n" for grep -e $_, $oldfile, $file;
 
	# Preset some variables for upload; these may be changed below:
	my $assert = 'assert';  # for AssertEdit existence check
	my $comment = "Trying to fix wrong font rendering";
	my $newtext = $text;
  
	# Optionally, pause and ask for confirmation:
	while ($confirm) {
			print STDERR "  Do you want to upload $file? (Y/N): ";
			my $reply = <STDIN>;
			last if $reply =~ /^y(es)?$/i;
			next unless $reply =~ /^no?$/i;
			#2 == unlink $oldfile, $file or die "Error unlinking temp files: $!\n";
			next FILE;
	}
 
	# Do the upload:
	print STDERR "Uploading $file (".(-s $file)." bytes) as $title... ";
	my $upload = apireq(
			action => 'upload',
			file => [$file],
			filename => $title,
			comment => $comment,
			text => $newtext,
			watch => $watch,
			ignorewarnings => 1,
			token => $token,
			$assert => 'exists',
			);
	if (ref $upload ne 'HASH') {
	die "Got unexpected result:\n", Dumper($upload), "\n";
	} elsif ($upload->{error}) {
	die "Uploading $file failed ($upload->{error}{code}): $upload->{error}{info}\n";
	} elsif ($upload->{upload}{result} ne 'Success') {
	die "Uploading $file did not succeed ($upload->{upload}{result}):\n", Dumper($upload), "\n";
	} else {
	warn "OK\n";
	}
 
	# If the file name was changed, mark old name as superseded:
	if ($title ne $curtitle) {
	print STDERR "Marking $curtitle as superseded... ";
	my $edit = apireq(
			action => 'edit',
			text => "{{Superseded|$title|Converted from BMP to PNG format}}\n$text",
			title => "File:$curtitle",
			basetimestamp => $timestamp,
			lasttimestamp => strftime("%Y-%m-%dT%H:%M:%S", gmtime $starttime),
			summary => "superseded by [[:File:$title]], converted from BMP to PNG",
			minor => 1,
			bot => 1,
			token => $token,
			watchlist => ($watch ? 'watch' : 'nochange'),
			assert => 'exists',
			);
	if (ref $edit ne 'HASH') {
		die "Got unexpected result:\n", Dumper($edit), "\n";
	} elsif ($edit->{error}) {
		die "Editing $curtitle failed ($edit->{error}{code}): $edit->{error}{info}\n";
	} elsif ($edit->{edit}{result} ne 'Success') {
		die "Editing $curtitle did not succeed ($edit->{edit}{result}):\n", Dumper($edit), "\n";
	} else {
		warn "OK\n";
	}
	}
 
	#2 == unlink $oldfile, $file or die "Error unlinking temp files: $!\n";
 
	my $sleep = $delay - (time - $lasttime);
	warn "Sleeping $sleep seconds before next upload...\n" and sleep $sleep if $sleep > 0 and $title ne $ARGV[-1];
	$lasttime = time;
}
 
__END__