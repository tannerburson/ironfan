maintainer       "Philip (flip) Kromer - Infochimps, Inc"
maintainer_email "coders@infochimps.com"
license          "Apache 2.0"
long_description IO.read(File.join(File.dirname(__FILE__), 'README.md'))
version          "3.0.2"

description      "Installs/Configures cluster_chef"

depends          "runit"
depends          "provides_service"

recipe           "cluster_chef::burn_ami_prep",        "Burn Ami Prep"
recipe           "cluster_chef::default",              "Base configuration for cluster_chef"
recipe           "cluster_chef::virtualbox_metadata",  "Virtualbox Metadata"

%w[ debian ubuntu ].each do |os|
  supports os
end

attribute "cluster_chef/conf_dir",
  :display_name          => "",
  :description           => "",
  :default               => "/etc/cluster_chef"

attribute "cluster_chef/log_dir",
  :display_name          => "",
  :description           => "",
  :default               => "/var/log/cluster_chef"

attribute "cluster_chef/home_dir",
  :display_name          => "",
  :description           => "",
  :default               => "/etc/cluster_chef"

attribute "cluster_chef/user",
  :display_name          => "",
  :description           => "",
  :default               => "root"

attribute "users/root/primary_group",
  :display_name          => "",
  :description           => "",
  :default               => "root"
