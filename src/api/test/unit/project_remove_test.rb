# Testing the things that should and shouldn't happen when you remove a Project
require File.expand_path(File.dirname(__FILE__) + "/..") + "/test_helper"

class ProjectRemoveTest < ActiveSupport::TestCase

  fixtures :all

  def setup
    CONFIG['global_write_through'] = true
  end

  def teardown
    CONFIG['global_write_through'] = false
  end

  def test_delete_cache_lines
    skip "No idea what CacheLine.cleanup_project is there for, Adrian?"
  end

  def test_cleanup_linking_projects
    skip "LinkedProject.linked_db_project = self are replaced with links to the 'deleted' project"
  end

  def test_cleanup_linking_repos
    skip "Project.repository.links.repository to this project repositories are replaced with links to the 'deleted' repository"
  end

  def test_cleanup_linking_targets
    skip "Project.repository.targetlinks.target_repository to this project repositories are replaced with links to the 'deleted' repository"
  end

  def test_cleanup_local_devel_packages
    skip "nullify the Packages in this Project that have develpackage_id"
  end

  def test_destroy_source_revokes_request
    User.current = users(:Iggy)
    branch_package
    create_request

    @package.project.destroy

    @request.reload
    assert_equal :revoked, @request.state
    assert_equal "The source project 'home:#{User.current.login}:branches:Apache' has been removed", @request.comment
    assert_equal 1, HistoryElement::RequestRevoked.where(op_object_id: @request.id).count
  end

  def test_destroy_target_declines_request
    User.current = users(:king)
    project = Project.create(name: 'test_destroy_target_declines_request')
    project.store
    project.packages.create(name: 'pack')

    User.current = users(:Iggy)
    branch_package('test_destroy_target_declines_request', 'pack')
    create_request('test_destroy_target_declines_request', 'pack')
    User.current = users(:king)
    Project.find_by(name: "test_destroy_target_declines_request").destroy
    @request.reload

    assert_equal :declined, @request.state
    assert_equal "The target project 'test_destroy_target_declines_request' has been removed", @request.comment
    assert_equal 1, HistoryElement::RequestDeclined.where(op_object_id: @request.id).count
  end

  def test_accept_request_does_not_revoke_request
    User.current = users(:Iggy)
    branch_package
    create_request

    User.current = users(:fred)
    @request.change_state(newstate: 'accepted',
                          force: true,
                          user: 'fred')

    assert_equal :accepted, @request.reload.state
    assert_equal 0, HistoryElement::RequestRevoked.where(op_object_id: @request.id).count
  end

  def test_review_gets_removed
    review_project = Project.create(name: 'test_review_gets_removed')

    User.current = users(:Iggy)
    branch_package
    create_request
    @request.addreview(by_project: review_project.name)

    assert_equal 1, @request.reviews.count
    assert_equal 1, HistoryElement::RequestReviewAdded.where(op_object_id: @request.id).count

    review_project.destroy

    assert_equal 0, @request.reviews.count
    assert_equal 0, HistoryElement::RequestReviewAdded.where(op_object_id: @request.id).count
  end

  def test_cleanup_packages
    skip "Project.packages get removed but not on the backend"
  end

  def test_delete_on_backend
    skip "Project is also deleted on the backend"
  end

  private

  # FIXME: A test mixin? Hmmm....
  def branch_package(project = 'Apache', package = 'apache2')
    # Branch a package and change it's contents
    BranchPackage.new(project: project, package: package).branch
    @package = Package.find_by_project_and_name("home:#{User.current.login}:branches:#{project}", package)
    @package.save_file(file: 'whatever', filename: 'testfile')
  end

  def create_request(project = 'Apache', package = 'apache2')
    # Create a request to submit the changes back
    request = BsRequest.new(state: "new", description: 'project_remove_test')
    action = BsRequestActionSubmit.new(source_project: "home:#{User.current.login}:branches:#{project}",
                                       source_package: package,
                                       target_project: project,
                                       target_package: package,
                                       sourceupdate: 'update')
    request.bs_request_actions << action
    action.bs_request = request
    request.set_add_revision
    request.save!
    @request = request.reload

    # The request should be new
    assert_equal :new, @request.reload.state
  end

end
