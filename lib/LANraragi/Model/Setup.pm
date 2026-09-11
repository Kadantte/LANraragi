package LANraragi::Model::Setup;
use strict;
use warnings;
use utf8;

use LANraragi::Model::Config;
use LANraragi::Utils::Logging qw(get_logger);
use LANraragi::Model::Category;
use LANraragi::Model::Registry;

use Exporter 'import';
our @EXPORT_OK = qw(first_install_actions);

# Default plugin registry seeded on first install.
use constant DEFAULT_REGISTRY_NAME     => "Ougi";
use constant DEFAULT_REGISTRY_URL      => "https://github.com/Difegue/Ougi.git";
use constant DEFAULT_REGISTRY_REF      => "main";

# first_install_actions()
# Setup tasks for first-time installations. 
# New installs are checked by confirming updated user settings. 
# 
# On first installation: 
# - Create default 'Favorites' category, link it to the bookmark button
# - Seed Ougi as the default plugin registry. 
# Returns 1 if is first-time installation, else 0.
sub first_install_actions {
    my $redis = LANraragi::Model::Config->get_redis_config();
    my $logger = get_logger( "Config", "lanraragi" );
    unless ( $redis->hexists('LRR_CONFIG', 'htmltitle') ) {
        $logger->info("First-time installation detected!");
        $redis->hset('LRR_CONFIG', 'htmltitle', 'LANraragi');

        $logger->debug("Creating first category...");
        my $default_category_id = LANraragi::Model::Category::create_category("🔖 Favorites", "", 0, "");
        LANraragi::Model::Category::update_bookmark_link($default_category_id);
        $logger->info("Created default Favorites category.");

        $logger->debug("Adding default plugin registry...");
        my ( $registry_id, $error ) = LANraragi::Model::Registry::create_registry(
            {
                name     => DEFAULT_REGISTRY_NAME,
                provider => "github",
                url      => DEFAULT_REGISTRY_URL,
                ref      => DEFAULT_REGISTRY_REF,
            },
            $redis
        );
        if ($error) {
            $logger->warn("Could not seed default plugin registry: $error");
        } else {
            my ( $status, undef, $update_error ) =
                LANraragi::Model::Registry::update_default_registry( $registry_id, $redis );
            if ( $status == 200 ) {
                $logger->info("Added plugin registry '$registry_id' and set it as the default.");
            } else {
                $logger->warn("Created plugin registry '$registry_id' but failed to set it as default: $update_error");
            }
        }

        $redis->quit();
        return 1;
    }
    $redis->quit();
    return 0;
}

1;
