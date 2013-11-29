# Copyright (c) 2009, GoodData Corporation. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
# Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
# Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
# Neither the name of the GoodData Corporation nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS
# OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
# AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
# WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.



module PowerByHelper


  class User
    def initialize()
      load_data_structure()
    end

    def load_data_structure()

      user_creation_mapping = Settings.deployment_user_creation["mapping"]
      user_synchronization_mapping = Settings.deployment_user_project_synchronization["mapping"]

      user_creation_file_name = Settings.deployment_user_creation["source"]
      user_project_creation_file_name = Settings.deployment_user_project_synchronization["source"]

      #In case of remote file location, lets download file to local first
      if (Settings.deployment_user_creation_type == "webdav")
        Helper.download_file_from_webdav(user_creation_file_name,Settings.default_user_data_file_name)
        user_creation_file_name = Settings.default_user_data_file_name
      end

      if (Settings.deployment_user_project_synchronization_type == "webdav")
        Helper.download_file_from_webdav(user_project_creation_file_name,Settings.default_user_project_synchronization_data_file_name)
        user_project_creation_file_name = Settings.default_user_project_synchronization_data_file_name
      end

      #Checks
      fail "User data file don't exists" unless File.exists?(user_creation_file_name)
      fail "User project data file don't exists" unless File.exists?(user_project_creation_file_name)
      fail "User creation mapping don't have all necessery fields" unless user_creation_mapping.has_key?("login") and user_creation_mapping.has_key?("first_name") and user_creation_mapping.has_key?("last_name")
      fail "User project synchronization  mapping don't have all necessery fields" unless user_synchronization_mapping.has_key?("ident") and user_synchronization_mapping.has_key?("login") and user_synchronization_mapping.has_key?("role") and user_synchronization_mapping.has_key?("notification")

      #Initializations
      Persistent.init_user
      Persistent.init_roles

      password_mapping = user_creation_mapping["password"] || "password"
      admin_mapping = user_creation_mapping["admin"] || "admin"

      # Load info about users - domain file - representing users which should be in domain and merge it with info in Persistent storage
      FasterCSV.foreach(user_creation_file_name, {:headers => true, :skip_blanks => true}) do |csv_obj|

        user_data = UserData.new({"login" => csv_obj[user_creation_mapping["login"]].downcase.strip, "first_name" => csv_obj[user_creation_mapping["first_name"]], "last_name" => csv_obj[user_creation_mapping["last_name"]], "status" => UserData.NEW})
        user_data.password = csv_obj[password_mapping] || rand(10000000000000).to_s


        if (!Helper.blank?(csv_obj[admin_mapping]))
          # The admin mapping field could contain 0/1 ... the user is automaticaly admin
          if (csv_obj[admin_mapping].to_s == "1")
            user_data.admin = true
          elsif (csv_obj[admin_mapping].to_s == "0")
            user_data.admin = false
          # The admin mapping field could contain gooddata role -> user will be created with this role
          elsif (Helper.roles.include?(csv_obj[admin_mapping].to_s))
            user_data.admin = true
            user_data.admin_role = csv_obj[admin_mapping].to_s
          else
            fail "Role provided for one user in domain file is invalid #{csv_obj[user_creation_mapping["login"]].downcase.strip} role: #{csv_obj[admin_mapping].to_s}"
          end
        else
          user_data.admin = false
        end
        Persistent.merge_user(user_data)
      end
      Persistent.store_user

      # Cleaning - mark all user_project mappings as disabled
      Persistent.user_project_data.each do |user_project_data|
        Persistent.change_user_project_status(user_project_data.login,user_project_data.project_pid,UserProjectData.TO_DISABLE,nil)
      end


      # Load info about user-project mapping and merge it with information from Persistent Storage
      FasterCSV.foreach(user_project_creation_file_name, {:headers => true, :skip_blanks => true}) do |csv_obj|

        ident = csv_obj[user_synchronization_mapping["ident"]]

        project_pid = Persistent.get_project_by_ident(ident)

        if (!project_pid.nil?)

          project_pid = project_pid.project_pid

          role = csv_obj[user_synchronization_mapping["role"]]
          check = Helper.roles.find{|r| r.downcase == role.downcase}
          fail "This role does not exist in Gooddata" if check.nil?

          login = csv_obj[user_synchronization_mapping["login"]].downcase.strip
          notification = csv_obj[user_synchronization_mapping["notification"]].to_s == "1" ? true : false
          internal_role = "external"
          if (!user_synchronization_mapping["internal_role"].nil?)
            internal_role = csv_obj[user_synchronization_mapping["internal_role"]].downcase
          end

          Persistent.change_user_project_status(login,project_pid,UserProjectData.NEW,
                                                {"login" => login,"project_pid" => project_pid, "notification" => notification, "internal_role" => internal_role,"role" => role}
          )


        else
          @@log.warn "Project with ID #{ident} don't exist. Skipping user #{csv_obj[user_synchronization_mapping["login"]].downcase} invitation"
        end
      end

      # Find all admin users and make them admin in all of the projects - merge this information with persistent storage
      admin_users = Persistent.get_users_by_admin
      projects = Persistent.get_projects
      admin_users.each do |admin_data|
        projects.each do |p|
          Persistent.change_user_project_status(admin_data.login,p.project_pid,UserProjectData.NEW,
                                                {"login" => admin_data.login,"project_pid" => p.project_pid, "notification" => false, "internal_role" => "internal", "role" =>  admin_data.admin_role}
          )
        end
      end



      # We are supporting disable feature on projects
      # DISABLED project for us is project, in which all users (except of users with role_internal == internal) are disabled
      projects_to_disable = Persistent.get_projects_by_status(ProjectData.DISABLED)
      Persistent.user_project_data.each do |user_project|
        temp = projects_to_disable.find do |p|
          p.project_pid == user_project.project_pid
        end
        is_disabled = temp.nil? ? false : true
        if (is_disabled and user_project.internal_role != "internal")
          Persistent.change_user_project_status(user_project.login,user_project.project_pid,UserProjectData.TO_DISABLE_BY_PROJECT,nil)
        end
      end

      @@log.info "Persistent storage for user provisioning initialized"


  end


    def create_new_users
      users_to_create = Persistent.get_users_by_status(UserData.NEW)
      users_in_domain = UserHelper.load_domain_users
      users_to_create.each do |user_data|
        domain_user = users_in_domain.find{|u| u[:login] == user_data.login}
        if (domain_user.nil?)
          @@log.info "Creating new user #{user_data.login} in domain"
          user_data = UserHelper.create_user_in_domain(Settings.deployment_user_domain,user_data)
          Persistent.merge_user(user_data) if !user_data.nil?
        else
          @@log.info "User #{user_data.login} already in domain - reusing"
          user_data.uri = domain_user[:profile]
          user_data.status = UserData.CREATED
          Persistent.merge_user(user_data)
        end
      end
      Persistent.store_user
    end

    def invite_users
       UserHelper.invite_user()

    end

    def add_users
      UserHelper.add_user()
    end


    def disable_users
      UserHelper.disable_user()
    end

    def update_users
      UserHelper.update_user()
    end

  end



  class UserData
    attr_accessor :uri,:login,:first_name,:last_name,:user_project_mapping,:password,:admin,:status,:admin_role


    def self.NEW
      "NEW"
    end

    def self.CREATED
      "CREATED"
    end

    def initialize(data)
      @uri = data["uri"] || ""
      @login = data["login"]
      @first_name = data["first_name"]
      @last_name = data["last_name"]
      @password = data["password"]
      @admin = data["admin"]
      # Add to support different then adminrole powerusers (users which are automaticaly invited to all projects)
      @admin_role = data["admin_role"] || "adminRole"
      @status = data["status"]
    end


    def self.header
      ["login","uri","first_name","last_name","admin","status"]
    end

    def to_a
      [@login,@uri,@first_name,@last_name, @admin, @status]
    end


  end


  class UserProjectData

    attr_accessor :project_pid,:role,:status,:notification, :notification_send, :internal_role, :login


    def self.NEW
      "NEW"
    end

    def self.CHANGED
      "CHANGED"
    end

    def self.OK
      "OK"
    end

    def self.TO_DISABLE
      "TO_DISABLE"
    end

    def self.TO_DISABLE_BY_PROJECT
      "TO_DISABLE_BY_PROJECT"
    end


    def self.DISABLED
      "DISABLED"
    end




    def initialize(status,data)
        @status = status
        @login = data["login"]
        @project_pid = data["project_pid"]
        @role = data["role"]
        @notification = data["notification"]
        @notification_send = data["notification_send"] || false
        @internal_role = data["internal_role"] || "external"
    end

    def self.header
      ["login","project_pid","role","status","notification","notification_send","internal_role"]
    end

    def to_a
      [@login,@project_pid,@role,@status, @notification, @notification_send, @internal_role]
    end




  end


end

