package LANraragi::Utils::Database;

use strict;
use warnings;
use utf8;

use Digest::SHA qw(sha256_hex);
use Mojo::JSON qw(decode_json);
use Encode;
use File::Basename;
use Redis;
use Cwd;
use Unicode::Normalize;

use LANraragi::Model::Plugins;
use LANraragi::Utils::Generic qw(remove_spaces);
use LANraragi::Utils::Logging qw(get_logger);

# Functions for interacting with the DB Model.
use Exporter 'import';
our @EXPORT_OK = qw(redis_encode redis_decode invalidate_cache compute_id);

#add_archive_to_redis($id,$file,$redis)
#Parses the name of a file for metadata, and matches that metadata to the SHA-1 hash of the file in our Redis database.
#This function doesn't actually require the file to exist at its given location.
sub add_archive_to_redis {
    my ( $id, $file, $redis ) = @_;
    my $logger = get_logger( "Archive", "lanraragi" );
    my ( $name, $path, $suffix ) = fileparse( $file, qr/\.[^.]*/ );

    #jam this shit in redis
    $logger->debug("Pushing to redis on ID $id:");
    $logger->debug("File Name: $name");
    $logger->debug("Filesystem Path: $file");

    $redis->hset( $id, "name",  redis_encode($name) );
    $redis->hset( $id, "title", redis_encode($name) );

    #Don't encode filenames.
    $redis->hset( $id, "file", $file );

    #New file in collection, so this flag is set.
    $redis->hset( $id, "isnew", "true" );

    $redis->quit;
    return $name;
}

# build_archive_JSON(redis, id)
# Builds a JSON object for an archive registered in the database and returns it.
# This function is usually called many times in a row, so provide your own Redis object.
sub build_archive_JSON {
    my ( $redis, $id ) = @_;

    #Extra check in case we've been given a bogus ID
    return "" unless $redis->exists($id);

    my %hash = $redis->hgetall($id);

    #It's not a new archive, but it might have never been clicked on yet,
    #so we'll grab the value for $isnew stored in redis.
    my ( $name, $title, $tags, $file, $isnew, $progress, $pagecount ) = @hash{qw(name title tags file isnew progress pagecount)};

    # return undef if the file doesn't exist.
    unless ( -e $file ) {
        return;
    }

    #Parameters have been obtained, let's decode them.
    ( $_ = redis_decode($_) ) for ( $name, $title, $tags );

    #Workaround if title was incorrectly parsed as blank
    if ( !defined($title) || $title =~ /^\s*$/ ) {
        $title = $name;
    }

    my $arcdata = {
        arcid     => $id,
        title     => $title,
        tags      => $tags,
        isnew     => $isnew,
        progress  => $progress ? int($progress) : 0,
        pagecount => $pagecount ? int($pagecount) : 0
    };

    return $arcdata;
}

#Deletes the archive with the given id from redis, and the matching archive file/thumbnail.
sub delete_archive {

    my $id       = $_[0];
    my $redis    = LANraragi::Model::Config->get_redis;
    my $filename = $redis->hget( $id, "file" );

    $redis->del($id);
    $redis->quit();

    if ( -e $filename ) {
        unlink $filename;

        my $thumbdir  = LANraragi::Model::Config->get_thumbdir;
        my $subfolder = substr( $id, 0, 2 );
        my $thumbname = "$thumbdir/$subfolder/$id.jpg";

        unlink $thumbname;

        return $filename;
    }

    return "0";
}

# drop_database()
# Drops the entire database. Hella dangerous
sub drop_database {
    my $redis = LANraragi::Model::Config->get_redis;

    $redis->flushall();
    $redis->quit;
}

# clean_database()
# Remove entries from the database that don't have a matching archive on the filesystem.
# Returns the number of entries deleted/unlinked.
sub clean_database {
    my $redis  = LANraragi::Model::Config->get_redis;
    my $logger = get_logger( "Archive", "lanraragi" );

    eval {
        # Save an autobackup somewhere before cleaning
        my $outfile = getcwd() . "/autobackup.json";
        open( my $fh, '>', $outfile );
        print $fh LANraragi::Model::Backup::build_backup_JSON();
        close $fh;
    };

    if ($@) {
        $logger->warn("Unable to open a file to save backup before cleaning database! $@");
    }

    # Get the filemap for ID checks later down the line
    my @filemapids = $redis->exists("LRR_FILEMAP") ? $redis->hvals("LRR_FILEMAP") : ();
    my %filemap = map { $_ => 1 } @filemapids;

    #40-character long keys only => Archive IDs
    my @keys = $redis->keys('????????????????????????????????????????');

    my $deleted_arcs  = 0;
    my $unlinked_arcs = 0;

    foreach my $id (@keys) {
        my $file = $redis->hget( $id, "file" );

        unless ( -e $file ) {
            $redis->del($id);
            $deleted_arcs++;
            next;
        }

        unless ( $file eq "" || exists $filemap{$id} ) {
            $logger->warn("File exists but its ID is no longer $id -- Removing file reference in its database entry.");
            $redis->hset( $id, "file", "" );
            $unlinked_arcs++;
        }
    }

    $redis->quit;
    return ( $deleted_arcs, $unlinked_arcs );
}

#add_tags($id, $tags)
#add the $tags to the archive with id $id.
sub add_tags {

    my ( $id, $newtags ) = @_;

    my $redis   = LANraragi::Model::Config->get_redis;
    my $oldtags = $redis->hget( $id, "tags" );
    $oldtags = redis_decode($oldtags);

    if ( length $newtags ) {

        if ($oldtags) {
            remove_spaces($oldtags);

            if ( $oldtags ne "" ) {
                $newtags = $oldtags . "," . $newtags;
            }
        }

        $redis->hset( $id, "tags", redis_encode($newtags) );
    }
    $redis->quit;
}

sub set_title {

    my ( $id, $newtitle ) = @_;
    my $redis = LANraragi::Model::Config->get_redis;

    if ( $newtitle ne "" ) {
        $redis->hset( $id, "title", redis_encode($newtitle) );
    }
    $redis->quit;
}

#This function is used for all ID computation in LRR.
#Takes the path to the file as an argument.
sub compute_id {

    my $file = $_[0];

    #Read the first 500 KBs only (allows for faster disk speeds )
    open( my $handle, '<', $file ) or die "Couldn't open $file :" . $!;
    my $data;
    my $len = read $handle, $data, 512000;
    close $handle;

    #Compute a SHA-1 hash of this data
    my $ctx = Digest::SHA->new(1);
    $ctx->add($data);
    my $digest = $ctx->hexdigest;

    if ( $digest eq "da39a3ee5e6b4b0d3255bfef95601890afd80709" ) {
        die "Computed ID is for a null value, invalid source file.";
    }

    return $digest;

}

# Normalize the string to Unicode NFC, then layer on redis_encode for Redis-safe serialization.
sub redis_encode {

    my $data     = $_[0];
    my $NFC_data = NFC($data);

    return encode_utf8($NFC_data);
}

#Final Solution to the Unicode glitches -- Eval'd double-decode for data obtained from Redis.
#This should be a one size fits-all function.
sub redis_decode {

    my $data = $_[0];

    # Setting FB_CROAK tells encode to die instantly if it encounters any errors.
    # Without this setting, it typically tries to replace characters... which might already be valid UTF8!
    eval { $data = decode_utf8( $data, Encode::FB_CROAK ) };

    # Do another UTF-8 decode just in case the data was double-encoded
    eval { $data = decode_utf8( $data, Encode::FB_CROAK ) };

    return $data;
}

# Bust the current search cache key in Redis.
# Add "1" as a parameter to perform a cache warm after the wipe.
sub invalidate_cache {
    my $do_warm = shift;
    my $redis   = LANraragi::Model::Config->get_redis;
    $redis->del("LRR_SEARCHCACHE");
    $redis->hset( "LRR_SEARCHCACHE", "created", time );
    $redis->quit();

    # Re-warm the cache to ensure sufficient speed on the main inde
    if ($do_warm) {
        LANraragi::Model::Config->get_minion->enqueue( warm_cache => [] => { priority => 3 } );
    }
}

# Go through the search cache and only invalidate keys that rely on isNew.
sub invalidate_isnew_cache {

    my $redis = LANraragi::Model::Config->get_redis;
    my %cache = $redis->hgetall("LRR_SEARCHCACHE");

    foreach my $cachekey ( keys(%cache) ) {

        # A cached search uses isNew if the second to last number is equal to 1
        # i.e, "--title-asc-1-0" has to be pruned
        if ( $cachekey =~ /.*-.*-.*-.*-1-\d?/ ) {
            $redis->hdel( "LRR_SEARCHCACHE", $cachekey );
        }
    }
    $redis->quit();
}

1;
