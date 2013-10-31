# the purpose of this mixin is to get the user functions having to do with ldap into one file
class UserLdapStrategy

  @@ldap_search_con = nil

  def is_in_group?(user, group)
    user_in_group_ldap? user.login, group
  end

  def local_role_check(role, object)
    local_role_check_with_ldap role, object
  end

  def local_permission_check(roles, object)
    groups = object.relationships.groups
    local_permission_check_with_ldap(groups.where("role_id in (?)", roles))
  end

  # This method returns all groups assigned to the given user via ldap - including
  # the ones he gets by being assigned through group inheritance.
  def all_groups_ldap(group_ldap)
    result = Array.new
    for group in group_ldap
      result << group.ancestors_and_self
    end

    result.flatten!
    result.uniq!

    return result
  end

  def groups(user)
    render_grouplist_ldap(Group.all, user.login)
  end

  # This static method tries to update the entry with the given info in the
  # active directory server.  Return the error msg if any error occurred
  def self.update_entry_ldap(login, newlogin, newemail, newpassword)
    logger.debug(" Modifying #{login} to #{newlogin} #{newemail} using ldap")

    if @@ldap_search_con.nil?
      @@ldap_search_con = initialize_ldap_con(CONFIG['ldap_search_user'], CONFIG['ldap_search_auth'])
    end
    ldap_con = @@ldap_search_con
    if ldap_con.nil?
      logger.debug("Unable to connect to LDAP server")
      return "Unable to connect to LDAP server"
    end
    user_filter = "(#{CONFIG['ldap_search_attr']}=#{login})"
    dn = String.new
    ldap_con.search(CONFIG['ldap_search_base'], LDAP::LDAP_SCOPE_SUBTREE, user_filter) do |entry|
      dn = entry.dn
    end
    if dn.empty?
      logger.debug("User not found in ldap")
      return "User not found in ldap"
    end

    # Update mail/password info
    entry = [
        LDAP.mod(LDAP::LDAP_MOD_REPLACE, CONFIG['ldap_mail_attr'], [newemail]),
    ]
    if newpassword
      case CONFIG['ldap_auth_mech']
        when :cleartext then
          entry << LDAP.mod(LDAP::LDAP_MOD_REPLACE, CONFIG['ldap_auth_attr'], [newpassword])
        when :md5 then
          require 'digest/md5'
          require 'base64'
          entry << LDAP.mod(LDAP::LDAP_MOD_REPLACE, CONFIG['ldap_auth_attr'], ["{MD5}"+Base64.b64encode(Digest::MD5.digest(newpassword)).chomp])
      end
    end
    begin
      ldap_con.modify(dn, entry)
    rescue LDAP::ResultError
      logger.debug("Error #{ldap_con.err} for #{login} mail/password changing")
      return "Failed to update entry for #{login}: error #{ldap_con.err}"
    end

    # Update the dn name if it is changed
    if not login == newlogin
      begin
        ldap_con.modrdn(dn, "#{CONFIG['ldap_name_attr']}=#{newlogin}", true)
      rescue LDAP::ResultError
        logger.debug("Error #{ldap_con.err} for #{login} dn name changing")
        return "Failed to update dn name for #{login}: error #{ldap_con.err}"
      end
    end

    return
  end

  # This static method tries to add the new entry with the given name/password/mail info in the
  # active directory server.  Return the error msg if any error occurred
  def self.new_entry_ldap(login, password, mail)
    require 'ldap'
    logger.debug("Add new entry for #{login} using ldap")
    if @@ldap_search_con.nil?
      @@ldap_search_con = initialize_ldap_con(CONFIG['ldap_search_user'], CONFIG['ldap_search_auth'])
    end
    ldap_con = @@ldap_search_con
    if ldap_con.nil?
      logger.debug("Unable to connect to LDAP server")
      return "Unable to connect to LDAP server"
    end
    case CONFIG['ldap_auth_mech']
      when :cleartext then
        ldap_password = password
      when :md5 then
        require 'digest/md5'
        require 'base64'
        ldap_password = "{MD5}"+Base64.b64encode(Digest::MD5.digest(password)).chomp
    end
    entry = [
        LDAP.mod(LDAP::LDAP_MOD_ADD, 'objectclass', CONFIG['ldap_object_class']),
        LDAP.mod(LDAP::LDAP_MOD_ADD, CONFIG['ldap_name_attr'], [login]),
        LDAP.mod(LDAP::LDAP_MOD_ADD, CONFIG['ldap_auth_attr'], [ldap_password]),
        LDAP.mod(LDAP::LDAP_MOD_ADD, CONFIG['ldap_mail_attr'], [mail]),
    ]
    # Added required sn attr
    if CONFIG.has_key('ldap_sn_attr_required') && CONFIG['ldap_sn_attr_required'] == :on
      entry << LDAP.mod(LDAP::LDAP_MOD_ADD, 'sn', [login])
    end

    begin
      ldap_con.add("#{CONFIG['ldap_name_attr']}=#{login},#{CONFIG['ldap_entry_base']}", entry)
    rescue LDAP::ResultError
      logger.debug("Error #{ldap_con.err} for #{login}")
      return "Failed to add a new entry for #{login}: error #{ldap_con.err}"
    end
    return
  end

  # This static method tries to delete the entry with the given login in the
  # active directory server.  Return the error msg if any error occurred
  def self.delete_entry_ldap(login)
    logger.debug("Deleting #{login} using ldap")
    if @@ldap_search_con.nil?
      @@ldap_search_con = initialize_ldap_con(CONFIG['ldap_search_user'], CONFIG['ldap_search_auth'])
    end
    ldap_con = @@ldap_search_con
    if ldap_con.nil?
      logger.debug("Unable to connect to LDAP server")
      return "Unable to connect to LDAP server"
    end
    user_filter = "(#{CONFIG['ldap_search_attr']}=#{login})"
    dn = String.new
    ldap_con.search(CONFIG['ldap_search_base'], LDAP::LDAP_SCOPE_SUBTREE, user_filter) do |entry|
      dn = entry.dn
    end
    if dn.empty?
      logger.debug("User not found in ldap")
      return "User not found in ldap"
    end
    begin
      ldap_con.delete(dn)
    rescue LDAP::ResultError
      logger.debug("Failed to delete: error #{ldap_con.err} for #{login}")
      return "Failed to delete the entry #{login}: error #{ldap_con.err}"
    end
    return
  end

  # This static method tries to find a group with the given gorup_title to check whether the group is in the LDAP server.
  def self.find_group_with_ldap(group)
    if CONFIG.has_key?('ldap_group_objectclass_attr')
      filter = "(&(#{CONFIG['ldap_group_title_attr']}=#{group})(objectclass=#{CONFIG['ldap_group_objectclass_attr']}))"
    else
      filter = "(#{CONFIG['ldap_group_title_attr']}=#{group})"
    end
    result = search_ldap(CONFIG['ldap_group_search_base'], filter)
    if result.nil?
      logger.debug("Fail to find group: #{group} in LDAP")
      return false
    else
      logger.debug("group dn: #{result[0]}")
      return true
    end
  end

  # This static method performs the search with the given search_base, filter
  def self.search_ldap(search_base, filter, required_attr = nil)
    if @@ldap_search_con.nil?
      @@ldap_search_con = initialize_ldap_con(CONFIG['ldap_search_user'], CONFIG['ldap_search_auth'])
    end
    ldap_con = @@ldap_search_con
    if ldap_con.nil?
      logger.debug("Unable to connect to LDAP server")
      return nil
    end
    logger.debug("Search: #{filter}")
    result = Array.new
    ldap_con.search(search_base, LDAP::LDAP_SCOPE_SUBTREE, filter) do |entry|
      result << entry.dn
      result << entry.attrs
      if required_attr and entry.attrs.include?(required_attr)
        result << entry.vals(required_attr)
      end
    end
    if result.empty?
      return nil
    else
      return result
    end
  end

  # This static method performs the search with the given grouplist, user to return the groups that the user in
  def self.render_grouplist_ldap(grouplist, user = nil)
    result = Array.new
    if @@ldap_search_con.nil?
      @@ldap_search_con = initialize_ldap_con(CONFIG['ldap_search_user'], CONFIG['ldap_search_auth'])
    end
    ldap_con = @@ldap_search_con
    if ldap_con.nil?
      logger.debug("Unable to connect to LDAP server")
      return result
    end

    if not user.nil?
      # search user
      if CONFIG.has_key?('ldap_user_filter')
        filter = "(&(#{CONFIG['ldap_search_attr']}=#{user})#{CONFIG['ldap_user_filter']})"
      else
        filter = "(#{CONFIG['ldap_search_attr']}=#{user})"
      end
      user_dn = String.new
      user_memberof_attr = String.new
      ldap_con.search(CONFIG['ldap_search_base'], LDAP::LDAP_SCOPE_SUBTREE, filter) do |entry|
        user_dn = entry.dn
        if CONFIG.has_key?('ldap_user_memberof_attr') && entry.attrs.include?(CONFIG['ldap_user_memberof_attr'])
          user_memberof_attr=entry.vals(CONFIG['ldap_user_memberof_attr'])
        end
      end
      if user_dn.empty?
        logger.debug("Failed to find #{user} in ldap")
        return result
      end
      logger.debug("User dn: #{user_dn} user_memberof_attr: #{user_memberof_attr}")
    end

    group_dn = String.new
    group_member_attr = String.new
    grouplist.each do |eachgroup|
      if eachgroup.kind_of? String
        group = eachgroup
      end
      if eachgroup.kind_of? Group
        group = eachgroup.title
      end

      unless group.kind_of? String
        raise ArgumentError, "illegal parameter type to user#render_grouplist_ldap?: #{eachgroup.class.name}"
      end

      # search group
      if CONFIG.has_key?('ldap_group_objectclass_attr')
        filter = "(&(#{CONFIG['ldap_group_title_attr']}=#{group})(objectclass=#{CONFIG['ldap_group_objectclass_attr']}))"
      else
        filter = "(#{CONFIG['ldap_group_title_attr']}=#{group})"
      end

      # clean group_dn, group_member_attr
      group_dn = ""
      group_member_attr = ""
      logger.debug("Search group: #{filter}")
      ldap_con.search(CONFIG['ldap_group_search_base'], LDAP::LDAP_SCOPE_SUBTREE, filter) do |entry|
        group_dn = entry.dn
        if CONFIG.has_key?('ldap_group_member_attr') && entry.attrs.include?(CONFIG['ldap_group_member_attr'])
          group_member_attr = entry.vals(CONFIG['ldap_group_member_attr'])
        end
      end
      if group_dn.empty?
        logger.debug("Failed to find #{group} in ldap")
        next
      end

      if user.nil?
        result << eachgroup
        next
      end

      # user memberof attr exist?
      if user_memberof_attr and user_memberof_attr.include?(group_dn)
        result << eachgroup
        logger.debug("#{user} is in #{group}")
        next
      end
      # group member attr exist?
      if group_member_attr and group_member_attr.include?(user_dn)
        result << eachgroup
        logger.debug("#{user} is in #{group}")
        next
      end
      logger.debug("#{user} is not in #{group}")
    end

    return result
  end

  # This static method tries to update the password with the given login in the
  # active directory server.  Return the error msg if any error occurred
  def self.change_password_ldap(login, password)
    if @@ldap_search_con.nil?
      @@ldap_search_con = initialize_ldap_con(CONFIG['ldap_search_user'], CONFIG['ldap_search_auth'])
    end
    ldap_con = @@ldap_search_con
    if ldap_con.nil?
      logger.debug("Unable to connect to LDAP server")
      return "Unable to connect to LDAP server"
    end
    user_filter = "(#{CONFIG['ldap_search_attr']}=#{login})"
    dn = String.new
    ldap_con.search(CONFIG['ldap_search_base'], LDAP::LDAP_SCOPE_SUBTREE, user_filter) do |entry|
      dn = entry.dn
    end
    if dn.empty?
      logger.debug("User not found in ldap")
      return "User not found in ldap"
    end

    case CONFIG['ldap_auth_mech']
      when :cleartext then
        ldap_password = password
      when :md5 then
        require 'digest/md5'
        require 'base64'
        ldap_password = "{MD5}"+Base64.b64encode(Digest::MD5.digest(password)).chomp
    end
    entry = [
        LDAP.mod(LDAP::LDAP_MOD_REPLACE, CONFIG['ldap_auth_attr'], [ldap_password]),
    ]
    begin
      ldap_con.modify(dn, entry)
    rescue LDAP::ResultError
      logger.debug("Error #{ldap_con.err} for #{login}")
      return "#{ldap_con.err}"
    end

    return
  end

  # This static method tries to find a user with the given login and
  # password in the active directory server.  Returns nil unless
  # credentials are correctly found using LDAP.
  def self.find_with_ldap(login, password)
    logger.debug("Looking for #{login} using ldap")
    ldap_info = Array.new
    # use cache to check the password firstly
    key="ldap_cache_userpasswd:" + login
    require 'digest/md5'
    if Rails.cache.exist?(key)
      ar = Rails.cache.read(key)
      if ar[0] == Digest::MD5.digest(password)
        ldap_info[0] = ar[1]
        ldap_info[1] = ar[2]
        logger.debug("login success for checking with ldap cache")
        return ldap_info
      end
    end

    # When the server closes the connection, @@ldap_search_con.nil? doesn't catch it
    # @@ldap_search_con.bound? doesn't catch it as well. So when an error occurs, we
    # simply it try it a seccond time, which forces the ldap connection to
    # reinitialize (@@ldap_search_con is unbound and nil).
    ldap_first_try = true
    dn = String.new
    ldap_password = String.new
    user_filter = String.new
    1.times do
      if @@ldap_search_con.nil?
        @@ldap_search_con = initialize_ldap_con(CONFIG['ldap_search_user'], CONFIG['ldap_search_auth'])
      end
      ldap_con = @@ldap_search_con
      if ldap_con.nil?
        logger.debug("Unable to connect to LDAP server")
        return nil
      end

      if CONFIG.has_key?('ldap_user_filter')
        user_filter = "(&(#{CONFIG['ldap_search_attr']}=#{login})#{CONFIG['ldap_user_filter']})"
      else
        user_filter = "(#{CONFIG['ldap_search_attr']}=#{login})"
      end
      logger.debug("Search for #{user_filter}")
      begin
        ldap_con.search(CONFIG['ldap_search_base'], LDAP::LDAP_SCOPE_SUBTREE, user_filter) do |entry|
          dn = entry.dn
          ldap_info[0] = String.new(entry[CONFIG['ldap_mail_attr']][0])
          ldap_info[1] = String.new(entry[CONFIG['ldap_name_attr']][0])
          if CONFIG.has_key?('ldap_authenticate') && CONFIG['ldap_authenticate'] == :local
            if entry[CONFIG['ldap_auth_attr']] then
              ldap_password = entry[CONFIG['ldap_auth_attr']][0]
              logger.debug("Get auth_attr:#{ldap_password}")
            else
              logger.debug("Failed to get attr:#{CONFIG['ldap_auth_attr']}")
            end
          end
        end
      rescue
        logger.debug("Search failed:  error #{ @@ldap_search_con.err}: #{ @@ldap_search_con.err2string(@@ldap_search_con.err)}")
        @@ldap_search_con.unbind()
        @@ldap_search_con = nil
        if ldap_fist_try
          ldap_first_try = false
          redo
        end
        return nil
      end
    end
    if dn.empty?
      logger.debug("User not found in ldap")
      return nil
    end
    # Attempt to authenticate user
    case CONFIG['ldap_authenticate']
      when :local then
        authenticated = false
        case CONFIG['ldap_auth_mech']
          when :cleartext then
            if ldap_password == password then
              authenticated = true
            end
          when :md5 then
            require 'digest/md5'
            require 'base64'
            if ldap_password == "{MD5}"+Base64.b64encode(Digest::MD5.digest(password)) then
              authenticated = true
            end
        end
        if authenticated == true
          ldap_info[0] = String.new(entry[CONFIG['ldap_mail_attr']][0])
          ldap_info[1] = String.new(entry[CONFIG['ldap_name_attr']][0])
        end
      when :ldap then
        # Don't match the passwd locally, try to bind to the ldap server
        user_con= initialize_ldap_con(dn, password)
        if user_con.nil?
          logger.debug("Unable to connect to LDAP server as #{dn} using credentials supplied")
        else
          # Redo the search as the user for situations where the anon search may not be able to see attributes
          user_con.search(CONFIG['ldap_search_base'], LDAP::LDAP_SCOPE_SUBTREE, user_filter) do |entry|
            if entry[CONFIG['ldap_mail_attr']] then
              ldap_info[0] = String.new(entry[CONFIG['ldap_mail_attr']][0])
            end
            if entry[CONFIG['ldap_name_attr']] then
              ldap_info[1] = String.new(entry[CONFIG['ldap_name_attr']][0])
            else
              ldap_info[1] = login
            end
          end
          user_con.unbind()
        end
    end
    Rails.cache.write(key, [Digest::MD5.digest(password), ldap_info[0], ldap_info[1]], :expires_in => 2.minute)
    logger.debug("login success for checking with ldap server")
    ldap_info
  end

  def groups_ldap
    logger.debug "List the groups #{self.login} is in"
    ldapgroups = Array.new
    # check with LDAP
    if User.ldapgroup_enabled?
      grouplist = Group.all
      begin
        ldapgroups = User.render_grouplist_ldap(grouplist, self.login)
      rescue Exception
        logger.debug "Error occurred in searching user_group in ldap."
      end
    end
    return ldapgroups
  end

  def user_in_group_ldap?(user, group)
    grouplist = []
    if group.kind_of? String
      grouplist.push Group.find_by_title(group)
    else
      grouplist.push group
    end

    begin
      return true unless render_grouplist_ldap(grouplist, user).empty?
    rescue Exception
      logger.debug "Error occurred in searching user_group in ldap."
    end

    return false
  end

  def local_permission_check_with_ldap (group_relationships)
    group_relationships.each do |r|
      return false if r.group.nil?
      #check whether current user is in this group
      return true if user_in_group_ldap?(self.login, r.group)
    end
    logger.debug "Failed with local_permission_check_with_ldap"
    return false
  end

  def local_role_check_with_ldap (role, object)
    logger.debug "Checking role with ldap: object #{object.name}, role #{role.title}"
    rels = object.relationships.groups.where(:role_id => role.id).includes(:group)
    for rel in rels
      return false if rel.group.nil?
      #check whether current user is in this group
      return true if user_in_group_ldap?(self.login, rel.group)
    end
    logger.debug "Failed with local_role_check_with_ldap"
    return false
  end

  # this method returns a ldap object using the provided user name
  # and password
  def self.initialize_ldap_con(user_name, password)
    return nil unless defined?(CONFIG['ldap_servers'])
    ldap_servers = CONFIG['ldap_servers'].split(":")
    ping = false
    server = nil
    count = 0

    max_ldap_attempts = CONFIG.has_key?('ldap_max_attempts') ? CONFIG['ldap_max_attempts'] : 10

    while !ping and count < max_ldap_attempts
      count += 1
      server = ldap_servers[rand(ldap_servers.length)]
      # Ruby only contains TCP echo ping.  Use system ping for real ICMP ping.
      ping = system("ping", "-c", "1", server)
    end

    if count == max_ldap_attempts
      logger.debug("Unable to ping to any LDAP server: #{CONFIG['ldap_servers']}")
      return nil
    end

    logger.debug("Connecting to #{server} as '#{user_name}'")
    begin
      if CONFIG.has_key?('ldap_ssl') && CONFIG['ldap_ssl'] == :on
        port = CONFIG.has_key?('ldap_port') ? CONFIG['ldap_port'] : 636
        conn = LDAP::SSLConn.new(server, port)
      else
        port = CONFIG.has_key?('ldap_port') ? CONFIG['ldap_port'] : 389
        # Use LDAP StartTLS. By default start_tls is off.
        if CONFIG.has_key?('ldap_start_tls') && CONFIG['ldap_start_tls'] == :on
          conn = LDAP::SSLConn.new(server, port, true)
        else
          conn = LDAP::Conn.new(server, port)
        end
      end
      conn.set_option(LDAP::LDAP_OPT_PROTOCOL_VERSION, 3)
      if CONFIG.has_key?('ldap_referrals') && CONFIG['ldap_referrals'] == :off
        conn.set_option(LDAP::LDAP_OPT_REFERRALS, LDAP::LDAP_OPT_OFF)
      end
      conn.bind(user_name, password)
    rescue LDAP::ResultError
      if not conn.nil?
        conn.unbind()
      end
      logger.debug("Not bound:  error #{conn.err} for #{user_name}")
      return nil
    end
    logger.debug("Bound as #{user_name}")
    return conn
  end

end
