# Rails app setup

Use at your own risk.

Chef setup for Rails app, nginx, passenger, postgres/mysql, logrotate, munin (for postgres).

Call it like this:

    rails_server 'appname' do
      env_name 'production'
      user_name 'deploy'
      database 'postgres'
      db_user_password 'password' # appname_user
      server_names 'example.com altdomain.example.com'
      pre_start 'http://example.com'
    end

    rails_server 'appname' do
      env_name 'production'
      user_name 'deploy'
      database 'mysql'
      mysql_root_password 'password'
      db_user_password 'password' # appname_user
      server_names 'example.com altdomain.example.com'
      pre_start 'http://example.com'
    end


