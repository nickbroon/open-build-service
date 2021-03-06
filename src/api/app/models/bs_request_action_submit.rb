class BsRequestActionSubmit < BsRequestAction
  #### Includes and extends
  include RequestSourceDiff

  #### Constants

  #### Self config
  def self.sti_name
    :submit
  end

  #### Attributes
  #### Associations macros (Belongs to, Has one, Has many)
  #### Callbacks macros: before_save, after_save, etc.
  #### Scopes (first the default_scope macro if is used)
  #### Validations macros
  #### Class methods using self. (public and then private)
  #### To define class methods as private use private_class_method
  #### private

  #### Instance methods (public and then protected/private)
  def is_submit?
    true
  end

  def execute_accept(opts)
    # use the request description as comments for history
    source_history_comment = bs_request.description

    cp_params = {
      cmd:            "copy",
      user:           User.current.login,
      oproject:       source_project,
      opackage:       source_package,
      noservice:      1,
      requestid:      bs_request.number,
      comment:        source_history_comment,
      withacceptinfo: 1
    }
    cp_params[:orev] = source_rev if source_rev
    cp_params[:dontupdatesource] = 1 if sourceupdate == "noupdate"
    unless updatelink
      cp_params[:expand] = 1
      cp_params[:keeplink] = 1
    end

    # create package unless it exists already
    target_project = Project.get_by_name(self.target_project)
    if target_package
      target_package = target_project.packages.find_by_name(self.target_package)
    else
      target_package = target_project.packages.find_by_name(source_package)
    end

    relink_source = false
    unless target_package
      # check for target project attributes
      initialize_devel_package = target_project.find_attribute( "OBS", "InitializeDevelPackage" )
      # create package in database
      linked_package = target_project.find_package(self.target_package)
      if linked_package
        # exists via project links
        opts = { request: bs_request }
        opts[:makeoriginolder] = true if makeoriginolder
        instantiate_container(target_project, linked_package.update_instance, opts)
        target_package = target_project.packages.find_by_name(linked_package.name)
      else
        # new package, base container on source container
        answer = Backend::Connection.get("/source/#{URI.escape(source_project)}/#{URI.escape(source_package)}/_meta")
        newxml = Xmlhash.parse(answer.body)
        newxml['name'] = self.target_package
        newxml['devel'] = nil
        target_package = target_project.packages.new(name: newxml['name'])
        target_package.update_from_xml(newxml)
        target_package.flags.destroy_all
        target_package.remove_all_persons
        target_package.remove_all_groups
        if initialize_devel_package
          target_package.develpackage = Package.find_by_project_and_name( source_project, source_package )
          relink_source = true
        end
        target_package.store(comment: "submit request #{bs_request.number}", request: bs_request)
      end
    end

    cp_path = "/source/#{self.target_project}/#{self.target_package}"
    cp_path << Backend::Connection.build_query_from_hash(cp_params, [:cmd, :user, :oproject, :opackage,
                                                                     :orev, :expand, :keeplink, :comment,
                                                                     :requestid, :dontupdatesource, :noservice,
                                                                     :withacceptinfo])
    result = Backend::Connection.post cp_path
    result = Xmlhash.parse(result.body)
    set_acceptinfo(result["acceptinfo"])

    target_package.sources_changed

    # cleanup source project
    if relink_source && !(sourceupdate == "noupdate")
      # source package got used as devel package, link it to the target
      # re-create it via branch , but keep current content...
      h = {}
      h[:cmd] = "branch"
      h[:user] = User.current.login
      h[:comment] = "initialized devel package after accepting #{bs_request.number}"
      h[:requestid] = bs_request.number
      h[:keepcontent] = "1"
      h[:noservice] = "1"
      h[:oproject] = self.target_project
      h[:opackage] = self.target_package
      cp_path = "/source/#{CGI.escape(source_project)}/#{CGI.escape(source_package)}"
      cp_path << Backend::Connection.build_query_from_hash(h, [:user, :comment, :cmd, :oproject, :opackage, :requestid, :keepcontent])
      Backend::Connection.post cp_path
    elsif sourceupdate == "cleanup"
      source_cleanup
    end

    return unless self.target_package == "_product"

    Project.find_by_name!(self.target_project).update_product_autopackages
  end

  #### Alias of methods
end

# == Schema Information
#
# Table name: bs_request_actions
#
#  id                    :integer          not null, primary key
#  bs_request_id         :integer          indexed, indexed => [target_package_id], indexed => [target_project_id]
#  type                  :string(255)
#  target_project        :string(255)      indexed
#  target_package        :string(255)      indexed
#  target_releaseproject :string(255)
#  source_project        :string(255)      indexed
#  source_package        :string(255)      indexed
#  source_rev            :string(255)
#  sourceupdate          :string(255)
#  updatelink            :boolean          default(FALSE)
#  person_name           :string(255)
#  group_name            :string(255)
#  role                  :string(255)
#  created_at            :datetime
#  target_repository     :string(255)
#  makeoriginolder       :boolean          default(FALSE)
#  target_package_id     :integer          indexed => [bs_request_id]
#  target_project_id     :integer          indexed => [bs_request_id]
#  source_package_id     :integer          indexed
#  source_project_id     :integer          indexed
#
# Indexes
#
#  bs_request_id                                                    (bs_request_id)
#  index_bs_request_actions_on_bs_request_id_and_target_package_id  (bs_request_id,target_package_id)
#  index_bs_request_actions_on_bs_request_id_and_target_project_id  (bs_request_id,target_project_id)
#  index_bs_request_actions_on_source_package                       (source_package)
#  index_bs_request_actions_on_source_package_id                    (source_package_id)
#  index_bs_request_actions_on_source_project                       (source_project)
#  index_bs_request_actions_on_source_project_id                    (source_project_id)
#  index_bs_request_actions_on_target_package                       (target_package)
#  index_bs_request_actions_on_target_project                       (target_project)
#
# Foreign Keys
#
#  bs_request_actions_ibfk_1  (bs_request_id => bs_requests.id)
#
