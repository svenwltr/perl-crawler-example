#!/usr/bin/perl
=pod

=head1 NAME

getwebsite - a website spider

=head1 SYNOPSIS

getwebsite [options] website [target]

=head2 OPTIONS

=over 4

=item -h, --help

Prints a brief help message.

=item -m, --man

Prints a full documentation of this script.

=item -c, --convert-links

If set, this scripts rewrites the links of the downloaded sites.

=item -d, --depth

Set the maximum download deep for the website. Defaults to 0.

=item -q, --quiet

Turns off all output messages.

=item --debug

Turns on all debug messages.

=back
 
=head1 DESCRIPTION

This programm will download the given website and its media. 

=head1 ABOUT

B<Author:> Sven Walter

B<E-Mail:> sven.walter@wltr.eu

B<Version:> 1.0.beta

=head1 SOURCECODE

=head2 HINTS

=over 4

=item Variable name 'au' menas 'analyzed url'.

=item Variable name 'fu' means 'found url'.

=item Variables starting with an 'r' are references.

=back

=cut




use strict;
use warnings;
no warnings 'utf8'; # ignore weired warnings on writing utf-8 data in bin mode


use Getopt::Long;
use Pod::Usage;
use LWP;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use Term::ANSIColor;


=pod

=head2 GLOBAL VARS

=over 4

=item %opts

Stores als CLI arguments.

=item $browser

A LWP instance.

=item %au_hash

Contains all always downloaded 'au's. See &analyze_url for further information.

=item @replacement_list

A help variable for link converting. See &find_urls and &convert_links.

=back

=cut
my %opts = (); # cli arguments
my $browser = LWP::UserAgent->new();
my %au_hash = (); # already downloaded urls
my @replacement_list; # replacements for links convertion


=pod

=head2 PARSING COMMANDLINE

This part parses the commandline arguments and stores them in the global
hash %opts.

Hash keys are 'depth', 'convert', 'debug', 'quiet', 'url' and 'target'.

=cut
{
    # default values
    $opts{'depth'} = 0;
    $opts{'convert'} = 0;
    $opts{'debug'} = 0;
    $opts{'quiet'} = 0;
    
    # configure parser
    GetOptions('depth|d:i' => \$opts{'depth'},
               'convert-links|c' => \$opts{'convert'},
               'debug' => \$opts{'debug'},
               'quiet|q' => \$opts{'quiet'},
               'help|h' => sub { &usage_error() },
               'man' => sub { &pod2usage(-exitstatus => 0,
                                        -verbose => 2) });

    # get and check 1st positional argument
    $opts{'url'} = shift @ARGV;
    &usage_error("URL is missing!") if(!defined $opts{'url'});

    # get and check 2nd positional argument
    $opts{"target"} = shift @ARGV;
    $opts{'target'} = '.' if(!defined $opts{'target'});
}


=pod

=head2 MAIN

This part starts the script and initiates the first start of &get_website.

=cut
{
    my %au = &analyze_url($opts{'url'});
    &get_website(\%au, $opts{'depth'});
    
    # convert links if requested
    if($opts{"convert"}) {
        &convert_links();
    }
}


=pod

=head2 get_website

Manages the download of an URL and its media. Also, it starts the
searching for new links.

=head3 ARGS

$rau - referenced analyzed url; see &analyze_url for further information

$depth - current crawling depth

=head3 RETURN

Nothing.

=cut
sub get_website {
    my ($rau, $depth) = @_;
    $depth--;
    
    
    my $contents = &download_file($rau);
    return unless defined $contents; # eg if the file is already downloaded
    
    
    my @links = &find_urls($rau, $contents);
    
    foreach my $rfu (@links) {
        if($rfu->{'type'} eq 'link') {
            if( $depth >= 0 ) {
                &get_website($rfu->{'au'}, $depth) foreach(@links);
            }
        } elsif($rfu->{'type'} eq 'media') {
            &download_file($rfu->{'au'});
        }
    }
}


=pod

=head2 http_download

Downloads and returns the given resource.

=head3 ARGS

$rau - referenced analyzed url; see &analyze_url for further information

=head3 RETURN

Contents of $rau destination.

=cut
sub download_file {
    my ($rau) = @_;
    my $url = $rau->{"url"};
    my $raw = $rau->{"raw"};
    
    return if ($au_hash{$url});
    $au_hash{$url} = $rau;

    &print_info(qq(Downloading "$url".\n));
    &print_debug(qq(Raw URL: "$raw".\n));
    
    my $page = $browser->get($url);
    &runtime_error("Could not download URL '$url'.") unless defined $page;
    
    my $contents = $page->decoded_content();
    $rau->{"content_type"} = $page->content_type;
    
    if($rau->{"content_type"} eq "text/html") {
        $rau->{"path"} =~ s/^(.*?)(\.html)?$/$1.html/;
    }

    eval {
        &make_path($rau->{"dirname"});
    };
    return if $@;
    
    my $path = $rau->{"path"};
    open FILE, ">$path" or return; # &runtime_error("Could not open file '$path'.");
    binmode FILE, ":raw";
    print FILE $contents;
    close FILE;
    
    $contents;
}


=pod

=head2 find_urls

Searches in the HTML source code ($_) for links and returns them.

=head3 ARGS

$prau - parent reference analyzed url; see analyze_url

$_ - html source code

=head3 RETURN

A list of hashes with URL information. These hashes have the keys 'type', 'au',
'search' and maybe 'name'. This hash is called 'fu' in some parts.

=cut
sub find_urls {
    my ($prau, $_) = @_;
    $/ = undef;
    
    my @fu_list = ();
    
    my @media_result = m{(<(link|img|script)[^>]+(href|src)=(["'])([^'"]*?)\4[^>]*?>)}gos;
    while(my ($search, $tag, $attr, $q, $url) = splice(@media_result, 0, 5)) {
        my %au = &analyze_url($url, $prau);
        
        next unless %au; # if analyzing failed
        
        my %fu = (
            'type' => 'media',
            'au' => \%au,
            'search' => $search,
        );
        
        push @replacement_list, [$search, \%au];
        push @fu_list, \%fu;
    }
    
    
    my @link_result = m{(<a\s+[^>]*href=(['"])(.+?)\2.*?>)(.*?)</a>}gos;
    while(my ($search, $q, $url, $name) = splice(@link_result, 0, 4)) {
        my %au = &analyze_url($url, $prau);
        
        next unless %au; # if analyzing failed
        next unless($au{'domain'} eq $prau->{'domain'} ); # if outside this domain
        
        my %fu = (
            'type' => 'link',
            'au' => \%au,
            'search' => $search,
            'name' => $name,
        );
        
        push @replacement_list, [$search, \%au];
        push @fu_list, \%fu;
    }

    @fu_list;
}


=pod

=head2 analyze_url

Analyzes an URL and extract some information.

=head3 ARGS

$raw - the raw URL; given in the href attribute for example

$prau - the analyzed url from parent

=head3 RETURN

A hash with the following keys: 'raw', 'href', 'url', 'scheme', 'base',
'domain', 'path', 'dirname' and 'filename'.

=cut
sub analyze_url {
    # prau: parent reference analyzed url ;-)
    my ($raw, $prau) = @_;
    my $href = $raw;

    &print_debug(qq(Analyze URL: "$raw".\n));
    
    # in this case $url is input from CLI
    unless($prau) {
    
        # make sure the CLI input has a schema -- otherwise it would be
        # handled a relative url
        unless($href =~ m{^https?://}) {
            $href = "http://".$href;
        }
    }
    
    return if($href =~ /^mailto:/);
    return if($href =~ /^#/);
    return if($href =~ /^javascript:/);
    
    
    my $url = $href;
    # if the scheme is undefined
    $url =~ s{^//}{$prau->{"scheme"}};

    # if it is a domain relative link    
    $url = $prau->{"base"}.$url if( $url =~ m{^/} );

    # if it is a directory relative link
    if($prau) {
        my ($parent_dir_relative) = $prau->{"url"} =~ m{(.*/).*?};
        $url = $parent_dir_relative.$url if($url =~ m{^[^/]*$});
    }
    
    &print_debug(qq(Regenerated url: "$url".\n));
    my ($base, $scheme, $domain, $get) = $url =~ m{^((https?://)([^/]+))(.*)};
    $get = '/' unless $get;
    
    my $path = $opts{"target"}.'/'.$domain.$get;
    $path = $path."index.html" if( $path =~ m{/$} );

    # HACK: have to strip out some special chars
    $path =~ s/[\?&%]//g;
    
    
    my ($dirname, $filename) = $path =~ m{^(.*)/(.*?)$};
    
    my %au = (
        'raw' => $raw,
        'href' => $href,
        'url' => $url,
        'scheme' => $scheme,
        'base' => $base,
        'domain' => $domain,
        'path' => $path,
        'dirname' => $dirname,
        'filename' => $filename,
    );
    
    %au;
}


=pod

=head2 convert_links

Iterates over all links in %au_hash and replaces all possible links.

=head3 ARGS

None.

=head3 RETURN

Nothing.

=cut
sub convert_links {
    $/ = undef;
    &print_debug("\n\nStart link converting.\n\n");
    
    foreach my $rau (values %au_hash) {
        next unless ($rau->{'content_type'} eq "text/html");
        
        open FILE, "<".$rau->{'path'} or next;
        binmode FILE, ":utf8";
        my $contents = <FILE>;
        close FILE;

        &print_info('Converting links in "'.$rau->{'path'}."\'.\n");
        
        foreach (@replacement_list) {
            my ($search, $c_rau) = @$_;
            my $replace = $search;
            
        
            my $raw = $c_rau->{'raw'};
            my $relpath = &make_relative_to($c_rau->{'path'}, $rau->{'path'});
            
            next unless ($relpath);
        
            $replace =~ s/\Q$raw\E/$relpath/;
            $contents =~ s/\Q$search\E/$replace/;
        }
        
        open FILE, ">".$rau->{'path'} or next;
        binmode FILE, ":utf8";
        print FILE $contents;
        close FILE;
    }
}


=pod

=head2 make_relative_to

Makes the path $path related to the file or directory $related. That means you
can access $pathi relative, if you are in the directory of $related.

=head3 ARGS

$path - the path that will be made relative

$related - the related path

=head3 RETURN

The relative path.

=cut
sub make_relative_to {
    my ($path, $related) = @_;
    

    # make sure both paths are absolute
    $path = &abs_path($path);
    $related = &abs_path($related);
    
    
    # check wether both paths exists
    return unless($path and $related);


    # make relative to dir, not to file
    $related = dirname($related) unless (-d $related);
    

    # splite both paths
    my @path = split('/', $path);
    my @related = split('/', $related);


    # strip direcories that are the same in both path
    while(defined $path[0] and defined $related[0] and $path[0] eq $related[0]) {
        shift @path;
        shift @related;
    }


    # add "directory up" for each directory left
    unshift @path, ".." foreach(@related);
    
    
    # join to directory
    join("/", @path);
    
}


=pod

=head2 usage_error

Prints an error message to STDERR, prints usage and exits with error code 1.

=head3 ARGS

$_ - the message

=head3 RETURN

Nothing.

=cut
sub usage_error {
    if($_[0]) {
        print STDERR "\n", $_[0], "\n\n";
    }
    &pod2usage(2);
    exit 1;
}


=pod

=head2 runtime_error

Prints an error message and exits with error code 1.

=head3 ARGS

$_ - the message

=head3 RETURN

Nothing.

=cut
sub runtime_error {
    print STDERR "\n", $_[0], "\n";
    exit 1;
}


=pod

=head2 print_debug

Prints a debug message, if the flag is set.

=head3 ARGS

@_ - the message

=head3 RETURN

Nothing.

=cut
sub print_debug {
    if($opts{'debug'}) {
        print color("blue"), "DEBUG: ", @_, color("reset");
    }
}


=pod

=head2 print_info

Prints a info message, unless the quiet flag is set.

=head3 ARGS

@_ - the message

=head3 RETURN

Nothing.

=cut
sub print_info {
    unless($opts{'quiet'}) {
        print @_;
    }
}



