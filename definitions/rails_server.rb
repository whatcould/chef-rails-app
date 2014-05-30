require 'digest'

define :rails_server, env_name: 'production', user_name: 'deploy', database: 'postgres', db_user_password: nil, server_names: nil, pre_start: nil, vhost_template: nil do

  package "nodejs" # for Rails asset pipeline

  app_name = params[:app_name] || params[:name]
  user_name = params[:user_name]
  env_name = params[:env_name]

  # 'recursive' does not set owner;
  # see http://tickets.opscode.com/browse/CHEF-1621
  directory "/srv/#{app_name}"             do owner user_name end
  directory "/srv/#{app_name}/releases"    do owner user_name end
  directory "/srv/#{app_name}/shared"      do owner user_name end
  directory "/srv/#{app_name}/shared/log"  do owner user_name end

  directory "/srv/#{app_name}/shared/log/nginx" do
    owner user_name
    recursive true
  end

  nginx_vhost_template = params[:vhost_template] || "/etc/nginx/sites-available/rails-#{app_name}.conf"
  template nginx_vhost_template do
    source "nginx-rails.conf.erb"
    cookbook 'rails_app'
    variables(server_names: params[:server_names],
              app_name: app_name,
              rails_env: env_name,
              pre_start: params[:pre_start]
              )

    mode 0755
    action :create
    notifies :restart, "service[nginx]"
  end

  nginx_site "rails-#{app_name}.conf" do
    action :enable
  end

  logrotate_app "#{app_name}-nginx" do
    cookbook "logrotate"
    path [ "/srv/#{app_name}/shared/log/nginx/access.log /srv/#{app_name}/shared/log/nginx/error.log" ]
    frequency "daily"
    create "644 root root"
    rotate 7
    compress
    delaycompress
    sharedscripts
    postrotate "[ ! -f /var/run/nginx.pid ] || kill -USR1 `cat /var/run/nginx.pid`"
  end

  logrotate_app "rails-#{app_name}" do
    cookbook "logrotate"
    path [ "/srv/#{app_name}/shared/log/*.log" ]
    frequency "daily"
    create "644 root root"
    rotate 7
    compress
    delaycompress
    sharedscripts
    postrotate "touch /srv/#{app_name}/current/tmp/restart.txt"
  end


  if params[:database] == 'postgres'
    bash "create-application-user" do
      user 'postgres'
      code <<-EOH
    echo "CREATE USER #{app_name}_user;" | psql
      EOH
      not_if "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='#{app_name}_user'\""
      action :run
    end

    app_password = params[:db_user_password]
    hashed_password = Digest::MD5.hexdigest("#{app_password}#{app_name}_user")

    bash "assign-application-user-password" do
      user 'postgres'
      code <<-EOH
    echo "ALTER ROLE #{app_name}_user ENCRYPTED PASSWORD 'md5#{hashed_password}';" | psql
      EOH
      not_if "echo '\connect' | PGPASSWORD=#{app_password} psql --username=#{app_name}_user --no-password -h localhost"
      action :run
    end

    bash "create-application-db" do
      user 'postgres'
      code <<-EOH
    echo "CREATE DATABASE #{app_name}_#{env_name};" | psql
      EOH
      not_if "psql -tAc \"SELECT 1 from pg_database where datname='#{app_name}_#{env_name}';\""
      action :run
    end

    bash "grant-privs-on-application-db" do
      user 'postgres'
      code <<-EOH
    echo "GRANT ALL PRIVILEGES ON DATABASE #{app_name} to #{app_name}_user;" | psql
      EOH
      action :run
    end

    cpan_module "DBD::Pg"
    # Monitor database with munin
    %w(size scans cache transactions).each do |kind|
      munin_plugin "postgres_#{kind}_" do
        plugin "postgres_#{kind}_#{app_name}"
      end
    end
  else
    connection_info = {host: "localhost", username: 'root', password: params[:mysql_root_password]}
    database_name = "#{app_name}_#{env_name}"
    db_user_name = "#{app_name}_user"
    mysql_database database_name do
      connection connection_info
      action :create
    end

    mysql_database_user db_user_name do
      connection connection_info
      password params[:db_user_password]
      action :create
    end

    mysql_database_user db_user_name do
      connection connection_info
      database_name database_name
      privileges [:all]
      action :grant
    end

  end

  gem_package "bundler" do
    action :install
    gem_binary "/usr/local/ruby/#{node['ruby']['ruby-build-version']}/bin/gem"
  end

  # cap uses rake; until I can figure out how to make it do a bundle exec rake, or use binstubs, installing the correct rake version globally:
  gem_package "rake" do
    action :upgrade
    gem_binary "/usr/local/ruby/#{node['ruby']['ruby-build-version']}/bin/gem"
    version '10.1.0'
    options '--force'
  end

  directory "/srv/#{app_name}/shared/config"               do owner user_name end
  directory "/srv/#{app_name}/shared/config/initializers"  do owner user_name end
  directory "/srv/#{app_name}/shared/config/settings"      do owner user_name end

  if params[:database] == 'postgres'
    adapter = 'postgresql'
    port = 5432
    encoding = 'unicode'
  else
    adapter = 'mysql2'
    port = 3306
    encoding = 'utf8'
  end

  template "/srv/#{app_name}/shared/config/database.yml" do
    variables(environment: env_name,
              database: "#{app_name}_#{env_name}",
              user: "#{app_name}_user",
              password: data_bag_item('database', 'database_users')["#{app_name}_user"],
              adapter: adapter,
              encoding: encoding,
              port: port
              )
    source "database.yml.erb"
    cookbook 'rails_app'
    owner user_name
    mode "0644"
  end


end