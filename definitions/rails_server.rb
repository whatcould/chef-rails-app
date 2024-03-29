require 'digest'

define :rails_server, env_name: 'production', user_name: 'deploy', ruby_version: nil,
      database: 'postgres', db_user_password: nil, mysql_instance_name: nil, server_names: nil,
      enable_nginx: true, certbot_dir: nil, pre_start: nil, vhost_template: nil,
      vhost_name: nil, use_puma: true, passenger_ruby: nil, setup_sidekiq: false, db_pool: nil  do

  package "nodejs" # for Rails asset pipeline

  app_name = params[:app_name] || params[:name]
  user_name = params[:user_name]
  env_name = params[:env_name]
  ruby_version = params[:ruby_version] || node['ruby']['ruby-build-version']

  # 'recursive' does not set owner;
  # see http://tickets.opscode.com/browse/CHEF-1621
  directory "/srv/#{app_name}"             do owner user_name end
  directory "/srv/#{app_name}/releases"    do owner user_name end
  directory "/srv/#{app_name}/shared"      do owner user_name end
  directory "/srv/#{app_name}/shared/log"  do owner user_name end
  directory "/srv/#{app_name}/shared/tmp"  do owner user_name end
  directory "/srv/#{app_name}/shared/tmp/sockets"  do owner user_name end
  directory "/srv/#{app_name}/shared/tmp/pids"  do owner user_name end
  directory "/srv/#{app_name}/shared/sockets"  do owner user_name end

  directory "/srv/#{app_name}/shared/log/nginx" do
    owner user_name
    recursive true
  end

  nginx_vhost_name = params[:vhost_name] || "rails-#{app_name}"
  nginx_vhost_template = params[:vhost_template] || "nginx-rails.conf.erb"
  template "/etc/nginx/sites-available/#{nginx_vhost_name}.conf"  do
    source nginx_vhost_template
    cookbook 'rails_app'
    variables(server_names: params[:server_names],
              app_name: app_name,
              rails_env: env_name,
              pre_start: params[:pre_start],
              use_puma: params[:use_puma],
              certbot_dir: params[:certbot_dir],
              passenger_ruby: params[:passenger_ruby]
              )

    mode 0755
    action :create
    notifies :restart, "service[nginx]"
  end

  if params[:enable_nginx]
    nginx_site "rails-#{app_name}.conf" do
      action :enable
    end
  else
    enabled_conf = "/etc/nginx/sites-enabled/#{nginx_vhost_name}.conf"
    execute "rm #{enabled_conf}" do
      only_if { File.exist?(enabled_conf) }
    end
  end

  logrotate_app "#{app_name}-nginx" do
    cookbook "logrotate"
    path [ "/srv/#{app_name}/shared/log/nginx/access.log", "/srv/#{app_name}/shared/log/nginx/error.log" ]
    frequency "daily"
    create "660 deploy www-data"
    rotate 7
    options   ['missingok', 'delaycompress', 'notifempty']
    sharedscripts
    postrotate "[ ! -f /var/run/nginx.pid ] || kill -USR1 `cat /var/run/nginx.pid`"
  end

  logrotate_app "rails-#{app_name}" do
    cookbook "logrotate"
    path [ "/srv/#{app_name}/shared/log/*.log" ]
    frequency "daily"
    create "660 deploy www-data"
    rotate 7
    options   ['missingok', 'delaycompress', 'notifempty']
    postrotate "touch /srv/#{app_name}/current/tmp/restart.txt"
  end

  if params[:use_puma]
    template "/etc/systemd/system/puma-#{app_name}.service" do
      source 'puma-systemd.conf.erb'
      owner user_name
      cookbook 'rails_app'
      # group user_name
      mode '0644'
      variables(
        app_name: app_name
      )
    end
  end


  app_password = params[:db_user_password]

  if params[:database] == 'postgres'

    postgresql_user "#{app_name}_user" do
      password app_password
    end

        #
    # bash "create-application-user" do
    #   user 'postgres'
    #   code <<-EOH
    # echo "CREATE USER \"#{app_name}_user\";" | psql
    #   EOH
    #   not_if "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='#{app_name}_user'\""
    #   action :run
    # end
    #
    # hashed_password = Digest::MD5.hexdigest("#{app_password}#{app_name}_user")
    #
    # bash "assign-application-user-password" do
    #   user 'postgres'
    #   code <<-EOH
    # echo "ALTER ROLE `#{app_name}_user` ENCRYPTED PASSWORD 'md5#{hashed_password}';" | psql
    #   EOH
    #   not_if "echo '\connect' | PGPASSWORD=#{app_password} psql --username=#{app_name}_user --no-password -h localhost"
    #   action :run
    # end

    bash "create-application-db" do
      user 'postgres'
      code <<-EOH
    echo "CREATE DATABASE \"#{app_name}\";" | psql
      EOH
      not_if "psql -tAc \"SELECT 1 from pg_database where datname='#{app_name}';\""
      action :run
    end

    bash "grant-privs-on-application-db" do
      user 'postgres'
      code <<-EOH
    echo "GRANT ALL PRIVILEGES ON DATABASE \"#{app_name}\" to \"#{app_name}_user\";" | psql
      EOH
      action :run
    end

    package 'libpq-dev' # for DBD:Pg cpan
    cpan_module "DBD::Pg"
    # Monitor database with munin
    %w(size scans cache transactions).each do |kind|
      munin_plugin "postgres_#{kind}_" do
        plugin "postgres_#{kind}_#{app_name}"
      end
    end
  else
    mysql2_chef_gem 'default' do
      action :install
    end

    # if socket is not specified, tries to connect to default socket
    connection_info = {host: "localhost", username: 'root', password: params[:mysql_root_password], socket: "/var/run/mysql-#{params[:mysql_instance_name]}/mysqld.sock"}
    database_name = "#{app_name}"
    db_user_name = "#{app_name}_user"
    mysql_database database_name do
      connection connection_info
      action :create
    end

    mysql_database_user db_user_name do
      connection connection_info
      password app_password
      action :create
    end

    mysql_database_user db_user_name do
      connection connection_info
      database_name database_name
      password app_password
      privileges [:all]
      action :grant
    end

    # # https://github.com/flatrocks/cookbook-mysql_logrotate
    # mysql_logrotate_agent params[:mysql_instance_name] do
    #   mysql_password params[:mysql_logrotate_password]
    #   connection connection_info
    #   action :create
    # end

    logrotate_app 'mysql-server' do
      enable false
    end

  end

  # Assumes ruby_rbenv cookbook
  rbenv_gem 'bundler' do
    rbenv_version ruby_version
    version '1.17.3' # avoid issues with bundler 2
  end

  # cap uses rake; until I can figure out how to make it do a bundle exec rake, or use binstubs, installing the correct rake version globally:
  # gem_package "rake" do
  #   action :upgrade
  #   gem_binary "/usr/local/ruby/#{node['ruby']['ruby-build-version']}/bin/gem"
  #   version '10.1.0'
  #   options '--force'
  # end

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
              database: "#{app_name}",
              user: "#{app_name}_user",
              password: app_password,
              adapter: adapter,
              encoding: encoding,
              port: port
              )
    source "database.yml.erb"
    cookbook 'rails_app'
    owner user_name
    mode "0644"
  end


  if params[:setup_sidekiq]
    directory = "/srv/#{app_name}/current"

    service_name = "sidekiq@#{app_name}"
    reload_name = "#{service_name} systemd reload"

    execute reload_name do
      command 'systemctl daemon-reload'
      action :nothing
    end

    template "/lib/systemd/system/#{service_name}.service" do
      source "sidekiq-systemd.conf.erb"
      cookbook 'rails_app'
      owner 'root'
      group 'root'
      mode '0644'
      variables(
              app_name: app_name,
              user_name: user_name,
              group: 'sudo',
              directory: directory,
              log_directory: "/srv/#{app_name}/shared/log/sidekiq.log"
      )
      notifies :run, "execute[#{reload_name}]", :immediately
    end

    execute "enable service #{service_name}" do
      command "systemctl enable #{service_name}.service"
    end

    # monit calls out to systemd to do the start/stop
    monit_monitrc "sidekiq_#{app_name}" do
      variables(
              app_name: app_name,
              directory: directory,
              pid_file: "/srv/#{app_name}/shared/tmp/pids/sidekiq.pid"
      )
      template_source 'monit-sidekiq.erb'
      template_cookbook 'rails_app' # somehow chef is confused when other cookbook is specified above

    end

    # allow deploy user to restart sidekiq
    sudo "#{user_name}_sidekiq_#{app_name}" do
      users      [user_name]   # or a username
      runas     'root'
      nopasswd  true
      commands  ["/bin/systemctl start sidekiq@#{app_name}", "/bin/systemctl stop sidekiq@#{app_name}", "/bin/systemctl restart sidekiq@#{app_name}"]
    end
  end

end