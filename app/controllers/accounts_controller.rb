# This file is part of the OpenWISP User Management System
#
# Copyright (C) 2010 CASPUR (Davide Guerri d.guerri@caspur.it)
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

class AccountsController < ApplicationController
  before_filter :require_account, :only => [ :show, :edit, :update, :ajax_accounting_search ]
  before_filter :require_no_account, :only => [ :new, :create, :verify_credit_card, :secure_verify_credit_card ]
  before_filter :require_no_operator
  
  before_filter :load_account, :except => [ :new, :create, :verify ]

  protect_from_forgery :except => [ :verify_credit_card, :secure_verify_credit_card ]

  STATS_PERIOD = 14

  def load_account
    @account = @current_account
  end
  
  def new
    @account = Account.new( :verification_method => Account::VERIFY_BY_MOBILE, :state => 'Italy' )
    @countries = Country.find :all, :conditions => "disabled = 'f'", :order => :printable_name
    @mobile_prefixes = MobilePrefix.find :all, :conditions => "disabled = 'f'", :order => :prefix
    
    respond_to do |format|
      format.html
      format.mobile
    end
  end
  
  def create
    @account = Account.new(params[:account])
    @countries = Country.find :all, :conditions => "disabled = 'f'", :order => :printable_name
    @mobile_prefixes = MobilePrefix.find :all, :conditions => "disabled = 'f'", :order => :prefix
    
    @account.radius_groups << RadiusGroup.find_by_name(Configuration.get('default_radius_group'))
    
    if @account.save_with_captcha
      if @account.verification_method == Account::VERIFY_BY_MOBILE
        MiddleMan.worker(:house_keeper_worker).enq_remove_unverified_user(:arg => @account.id, :job_key => @account.id, :scheduled_at => Time.now + Configuration.get('mobile_phone_registration_expire').to_i)
      elsif @account.verification_method == Account::VERIFY_BY_CREDIT_CARD
        MiddleMan.worker(:house_keeper_worker).enq_remove_unverified_user(:arg => @account.id, :job_key => @account.id, :scheduled_at => Time.now + Configuration.get('credit_card_registration_expire').to_i)
      end
      redirect_to account_path
    else
      respond_to do |format|
        format.html   { render :action => :new }
        format.mobile { render :action => :new }
      end
    end
  end
  
  def show
    now = Date.today
    cur = now - STATS_PERIOD.days
    ups = []
    downs = []
    logins = []
    categories = []
    yAxisMaxValue = 0
    @show_graphs = false 
    while cur <= now do
      up_traffic   = @account.radius_accountings.sum( 'AcctInputOctets', :conditions => "DATE(AcctStartTime) = '#{cur.to_s}'" )
      down_traffic = @account.radius_accountings.sum( 'AcctOutputOctets', :conditions => "DATE(AcctStartTime) = '#{cur.to_s}'" )
      time_count = 0
      sessions = @account.radius_accountings.find(:all, :conditions => "Date(AcctStartTime) = '#{cur.to_s}'")

      sessions.each do |session|
        if session.AcctStopTime
          time_count += session.acct_stop_time - session.acct_start_time
        else
          time_count += Time.now - session.acct_start_time
        end
      end

      logins.push :name => cur.to_s, :value => (time_count.to_i / 60.0)
      categories.push cur.to_s
      ups.push    up_traffic
      downs.push  down_traffic
      
      yAxisMaxValue = down_traffic if yAxisMaxValue < down_traffic
      yAxisMaxValue = up_traffic if yAxisMaxValue < up_traffic  
      cur += 1.day
    end
    
    if yAxisMaxValue > 0
      @show_graphs = true
      @login_xml_data = 
        render_to_string :template => "common/SSFusionChart.xml", 
                         :locals => { :caption => t(:Last_x_days_time, :count => STATS_PERIOD),
                                      :suffix => 'Min',
                                      :decimal_precision => 0,
                                      :data => logins
                                    }, :layout => false
      @traffic_xml_data = 
        render_to_string :template => "common/MSFusionChart.xml", 
                         :locals => { :caption => t(:Last_x_days_traffic, :count => STATS_PERIOD),
                                      :suffix => 'B',
                                      :categories => categories,
                                      :format_number_scale => 1,
                                      :decimalPrecision => 2,
                                      :series => [ { :name => t(:Upload), :color => '56B9F9', :data => ups }, 
                                                   { :name => t(:Download), :color => 'FDC12E', :data => downs } ]
                                    }, :layout => false
    else
      @login_xml_data = @traffic_xml_data = "" 
    end

    respond_to do |format|
      if not Account::SELFVERIFICATION_METHODS.include?(@account.verification_method) and !@account.verified?
        format.html   { render :action => :no_verification }
        format.mobile { render :action => :no_verification }
      elsif @current_operator.nil? and !@account.verified?
        format.html   { render :action => :verification }
        format.mobile { render :action => :verification }
      else
        format.html
        format.mobile
      end
    end

  end
 
  def edit
    @countries = Country.find :all, :conditions => "disabled = 'f'", :order => :printable_name
    @mobile_prefixes = MobilePrefix.find :all, :conditions => "disabled = 'f'", :order => :prefix

    respond_to do |format|
      if not Account::SELFVERIFICATION_METHODS.include?(@account.verification_method) and !@account.verified?
        format.html   { render :action => :no_verification }
        format.mobile { render :action => :no_verification }
      elsif @current_operator.nil? and !@account.verified?
        format.html   { render :action => :verification }
        format.mobile { render :action => :verification }
      else
        format.html
        format.mobile
      end
    end
  end
  
  def update
    @countries = Country.find :all, :conditions => "disabled = 'f'", :order => :printable_name
    @mobile_prefixes = MobilePrefix.find :all, :conditions => "disabled = 'f'", :order => :prefix
    
    if !@current_operator.nil? or !@account.verified?
      render :action => :verification
    else
      to_disable = false
      
      if params[:account][:disable_account]
        to_disable = true
        params[:account].delete :disable_account
        @account.verified = false
      end
      
      if @account.update_attributes(params[:account])
        if to_disable
          flash[:notice] = I18n.t(:Account_disabled)
          current_account_session.destroy
          redirect_to :root
        else
          flash[:notice] = I18n.t(:Account_updated)
          redirect_to account_url
        end
      else
        render :action => :edit
      end
    end
  end
  
  def verification
    @account = self.current_account
    if @account.nil? # Account expired (and removed by the housekeeping backgroundrb job)
      respond_to do |format|
        if request.xhr? # Ajax request
          format.html   { render :partial => 'expired' }
          format.mobile { render :partial => 'expired' }
        else
          format.html   { render :action => 'expired' }
          format.mobile { render :action => 'expired' }
        end
      end        
    else
      respond_to do |format|
        if request.xhr? # Ajax request
          format.html   { render :partial => 'verification' }
          format.mobile { render :partial => 'verification' }
        else
          format.html   { render :action => 'verification' }
          format.mobile { render :action => 'verification' }
        end
      end
    end
  end

  def verify_credit_card
    # Method to be called by paypal (IPN) to
    # verify user. Invoice is the account's id.
    # I know this method is verbose but, since 
    # it is very important for it to be secure,
    # clarity is preferred to geekiness :D
    # TODO: disable and delete this method
    if params.has_key? :invoice
      user = User.find params[:invoice]
      
      user.credit_card_identity_verify!
    end
    render :nothing => true
  end

  def secure_verify_credit_card
    # Method to be called by paypal (IPN) to
    # verify user. Invoice is the account's id.
    # I know this method is verbose but, since 
    # it is very important for it to be secure,
    # clarity is preferred to geekiness :D
    if params.has_key?(:secret) and params[:secret] == Configuration.get("ipn_shared_secret")
      if params.has_key? :invoice
        user = User.find params[:invoice]
        
        user.credit_card_identity_verify!
      end
    end
    render :nothing => true
  end

  def ajax_accounting_search
    items_per_page = Configuration.get('default_radacct_results_per_page')

    sort = case params[:sort]
      when 'acct_start_time'          then "AcctStartTime"
      when 'acct_stop_time'           then "AcctStopTime"
      when 'acct_input_octets'       then "AcctInputOctets"
      when 'acct_output_octets'      then "AcctOutputOctets"
      when 'acct_start_time_rev'      then "AcctStartTime DESC"
      when 'acct_stop_time_rev'       then "AcctStopTime DESC"
      when 'acct_input_octets_rev'   then "AcctInputOctets DESC"
      when 'acct_output_octets_rev'  then "AcctOutputOctets DESC"
    end
    if sort.nil?
      params[:sort] = "acct_start_time_rev"
      sort = "AcctStartTime DESC"
    end

    search = params[:search]
    page = params[:page].nil? ? 1 : params[:page]

    @total_accountings =  @account.radius_accountings.count
    @radius_accountings = @account.radius_accountings.paginate :page => page, :order => sort, :per_page => items_per_page

    render :partial => "common/radius_accounting_list", :locals => { :action => 'ajax_accounting_search', :accountings => @radius_accountings, :total_accountings => @total_accountings } 
  end
  
end
