class AssignmentsController < ApplicationController
  auto_complete_for :user, :name
  before_filter :authorize

  # change access permission from public to private or vice versa
  def toggle_access
    assignment = Assignment.find(params[:id])
    assignment.private = !assignment.private
    assignment.save
    redirect_to :controller => 'tree_display', :action => 'list'
  end

  def new
    @assignment = Assignment.new
    @assignment.course = Course.find(params[:parent_id]) if params[:parent_id]

    @assignment.instructor = @assignment.course.instructor if @assignment.course
    @assignment.instructor ||= current_user

    @assignment.wiki_type_id = 1 #default no wiki type
    @assignment.max_team_size = 1
  end

  def create
    @assignment = Assignment.new(params[:assignment])

    if @assignment.save
      @assignment.create_node
      flash[:success] = 'Assignment was successfully created.'
      redirect_to controller: :assignments, action: :edit, id: @assignment.id
    else
      render 'new'
    end
  end

  def edit
    @assignment = Assignment.find(params[:id])
    set_up
  end

  def delete_all_due_dates
    if params[:assignment_id].nil?
      return
    end

    assignment = Assignment.find(params[:assignment_id])
    if assignment.nil?
      return 
    end

    @due_dates = DueDate.find_all_by_assignment_id(params[:assignment_id])
    @due_dates.each do |due_date|
      due_date.delete
    end

    respond_to do |format|
      format.json { render :json => @due_dates }
    end
  end

  def set_due_date
    if params[:due_date][:assignment_id].nil?
      return 
    end

    assignment = Assignment.find(params[:due_date][:assignment_id])
    if assignment.nil?
      return 
    end

    due_at = DateTime.parse(params[:due_date][:due_at])
    if due_at.nil?
      return 
    end

    @due_date = DueDate.new(params[:due_date])
    @due_date.save

    respond_to do |format|
      format.json { render :json => @due_date }
    end
  end

  def delete_all_questionnaires
    assignment = Assignment.find(params[:assignment_id])
    if assignment.nil?
      return
    end

    @assignment_questionnaires = AssignmentQuestionnaire.find_all_by_assignment_id(params[:assignment_id])
    @assignment_questionnaires.each do |assignment_questionnaire|
      assignment_questionnaire.delete
    end

    respond_to do |format|
      format.json { render :json => @assignment_questionnaires }
    end
  end

  def set_questionnaire
    if params[:assignment_questionnaire][:assignment_id].nil? or params[:assignment_questionnaire][:questionnaire_id].nil?
      return
    end

    assignment = Assignment.find(params[:assignment_questionnaire][:assignment_id])
    if assignment.nil?
      return
    end

    questionnaire = Questionnaire.find(params[:assignment_questionnaire][:questionnaire_id])
    if questionnaire.nil?
      return 
    end

    @assignment_questionnaire = AssignmentQuestionnaire.new(params[:assignment_questionnaire])
    @assignment_questionnaire.save

    respond_to do |format|
      format.json { render :json => @assignment_questionnaire }
    end
  end


  def update
    @assignment = Assignment.find(params[:id])
    params[:assignment][:wiki_type_id] = 1 unless params[:assignment_wiki_assignment]

    #TODO: require params[:assignment][:directory_path] to be not null
    #TODO: insert warning if directory_path is duplicated

    if @assignment.update_attributes(params[:assignment])
      flash[:note] = 'Assignment was successfully saved.'
      #TODO: deal with submission path change
      # Need to rename the bottom-level directory and/or move intermediate directories on the path to an
      # appropriate place
      # Probably there are 2 different operations:
      #  - rename an assgt. -- implemented by renaming a directory
      #  - assigning an assignment to a course -- implemented by moving a directory.

      redirect_to :action => 'edit', :id => @assignment.id
    else
      flash[:error] = 'Assignment save failed.'
      redirect_to :action => 'edit', :id => @assignment.id
    end

    #respond_to do |format|
    #  format.json { render :json => params }
    #end
  end

  def show
    @assignment = Assignment.find(params[:id])
  end


#NOTE: many of these functions actually belongs to other models
#====setup methods for new and edit method=====#
  def set_up
    set_up_defaults

    submissions = @assignment.find_due_dates('submission') + @assignment.find_due_dates('resubmission')
    reviews = @assignment.find_due_dates('review') + @assignment.find_due_dates('rereview')
    @assignment.rounds_of_reviews = [@assignment.rounds_of_reviews, submissions.count, reviews.count].max

    if @assignment.directory_path.try :empty?
      @assignment.directory_path = nil
    end
  end

  #NOTE: unfortunately this method is needed due to bad data in db @_@
  def set_up_defaults
    if @assignment.require_signup.nil?
      @assignment.require_signup = false
    end
    if @assignment.wiki_type.nil?
      @assignment.wiki_type = WikiType.find_by_name('No')
    end
    if @assignment.staggered_deadline.nil?
      @assignment.staggered_deadline = false
      @assignment.days_between_submissions = 0
    end
    if @assignment.availability_flag.nil?
      @assignment.availability_flag = false
    end
    if @assignment.microtask.nil?
      @assignment.microtask = false
    end
    if @assignment.reviews_visible_to_all.nil?
      @assignment.reviews_visible_to_all = false
    end
    if @assignment.review_assignment_strategy.nil?
      @assignment.review_assignment_strategy = ''
    end
    if @assignment.require_quiz.nil?
      @assignment.require_quiz =  false
      @assignment.num_quiz_questions =  0
    end
  end


  # this function finds all the due_dates for a given assignment and calculates the time when the reminder for these deadlines needs to be sent. Enqueues them in the delayed_jobs table
  def add_to_delayed_queue
    due_dates = @assignment.due_dates
    due_dates.each do |due_date|
      deadline_type_name = due_date.deadline_type.name
      seconds_until_due = due_at - Time.now
      minutes_until_due = seconds_until_due / 60
      dj = Delayed::Job.enqueue(DelayedMailer.new(@assignment.id, deadline_type_name, due_at), 1, minutes_until_due)
      due_date.update_attribute(:delayed_job_id, dj.id)
    end
  end

  # Deletes the job with id equal to "delayed_job_id" from the delayed_jobs queue
  def delete_from_delayed_queue(delayed_job_id)
    dj=Delayed::Job.find(delayed_job_id)
    if (dj != nil && dj.id != nil)
      dj.delete
    end
  end

  #--------------------------------------------------------------------------------------------------------------------
  # GET_PATH (Helper function for CREATE and UPDATE)
  #  return the file location if there is any for the assignment
  # TODO: to be depreicated
  #--------------------------------------------------------------------------------------------------------------------
  def get_path
    begin
      file_path = @assignment.get_path
    rescue
      file_path = nil
    end
    return file_path
  end


  #--------------------------------------------------------------------------------------------------------------------
  # COPY_PARTICIPANTS_FROM_COURSE
  #  if assignment and course are given copy the course participants to assignment
  # TODO: to be tested
  #--------------------------------------------------------------------------------------------------------------------
  def copy_participants_from_course
    if params[:assignment][:course_id]
      begin
        Course.find(params[:assignment][:course_id]).copy_participants(params[:id])
      rescue
        flash[:error] = $!
      end
    end
  end

  #-------------------------------------------------------------------------------------------------------------------
  # COPY
  # Creates a copy of an assignment along with dates and submission directory
  # TODO: need to be tested
  #-------------------------------------------------------------------------------------------------------------------
  def copy
    Assignment.record_timestamps = false
    old_assign = Assignment.find(params[:id])
    new_assign = old_assign.clone
    @user = ApplicationHelper::get_user_role(session[:user])
    @user = session[:user]
    @user.set_instructor(new_assign)
    new_assign.update_attribute('name', 'Copy of ' + new_assign.name)
    new_assign.update_attribute('created_at', Time.now)
    new_assign.update_attribute('updated_at', Time.now)

    if new_assign.directory_path.present?
      new_assign.update_attribute('directory_path', new_assign.directory_path + '_copy')
    end

    session[:copy_flag] = true
    new_assign.copy_flag = true

    if new_assign.save
      Assignment.record_timestamps = true

      old_assign.assignment_questionnaires.each do |aq|
        AssignmentQuestionnaire.create(
            :assignment_id => new_assign.id,
            :questionnaire_id => aq.questionnaire_id,
            :user_id => session[:user].id,
            :notification_limit => aq.notification_limit,
            :questionnaire_weight => aq.questionnaire_weight
        )
      end

      DueDate.copy(old_assign.id, new_assign.id)
      new_assign.create_node()

      flash[:note] = 'Warning: The submission directory for the copy of this assignment will be the same as the submission directory for the existing assignment, which will allow student submissions to one assignment to overwrite submissions to the other assignment.  If you do not want this to happen, change the submission directory in the new copy of the assignment.'

      redirect_to :action => 'edit', :id => new_assign.id
    else
      flash[:error] = 'The assignment was not able to be copied. Please check the original assignment for missing information.'
      redirect_to :action => 'list', :controller => 'tree_display'
    end
  end


  #--------------------------------------------------------------------------------------------------------------------
  # DELETE
  # TODO: not been cleanup yep
  #--------------------------------------------------------------------------------------------------------------------
  def delete
    assignment = Assignment.find(params[:id])

    # If the assignment is already deleted, go back to the list of assignments
    if assignment
      begin
        #delete from delayed_jobs queue
        djobs = Delayed::Job.find(:all, :conditions => ['handler LIKE "%assignment_id: ?%"', assignment.id])
        for dj in djobs
          delete_from_delayed_queue(dj.id)
        end

        @user = session[:user]
        id = @user.get_instructor
        if (id != assignment.instructor_id)
          raise "Not authorised to delete this assignment"
        end
        assignment.delete(params[:force])
        @a = Node.find(:first, :conditions => ['node_object_id = ? and type = ?', params[:id], 'AssignmentNode'])

        @a.destroy
        flash[:notice] = "The assignment is deleted"
      rescue
        url_yes = url_for :action => 'delete', :id => params[:id], :force => 1
        url_no = url_for :action => 'delete', :id => params[:id]
        error = $!
        flash[:error] = error.to_s + " Delete this assignment anyway?&nbsp;<a href='#{url_yes}'>Yes</a>&nbsp;|&nbsp;<a href='#{url_no}'>No</a><BR/>"
      end
    end

    redirect_to :controller => 'tree_display', :action => 'list'
  end

  def list
    set_up_display_options("ASSIGNMENT")
    @assignments=super(Assignment)
    #    @assignment_pages, @assignments = paginate :assignments, :per_page => 10
  end


  #--------------------------------------------------------------------------------------------------------------------
  # DEFINE_INSTRUCTOR_NOTIFICATION_LIMIT
  # TODO: NO usages found need verification
  #--------------------------------------------------------------------------------------------------------------------
  def define_instructor_notification_limit(assignment_id, questionnaire_id, limit)
    existing = NotificationLimit.find(:first, :conditions => ['user_id = ? and assignment_id = ? and questionnaire_id = ?', session[:user].id, assignment_id, questionnaire_id])
    if existing.nil?
      NotificationLimit.create(:user_id => session[:user].id,
                               :assignment_id => assignment_id,
                               :questionnaire_id => questionnaire_id,
                               :limit => limit)
    else
      existing.limit = limit
      existing.save
    end
  end

  def associate_assignment_to_course
    puts '>>>>' + params[:id].to_s
    @assignment = Assignment.find(params[:id])
    @assignment.inspect
    @user = ApplicationHelper::get_user_role(session[:user])
    @user = session[:user]
    @courses = @user.set_courses_to_assignment
  end

  def remove_assignment_from_course
    assignment = Assignment.find(params[:id])
    oldpath = assignment.get_path rescue nil
    assignment.course_id = nil
    assignment.save
    newpath = assignment.get_path rescue nil
    FileHelper.update_file_location(oldpath, newpath)
    redirect_to :controller => 'tree_display', :action => 'list'
  end



end
