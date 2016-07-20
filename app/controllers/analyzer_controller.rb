require 'rubygems'
require 'fileutils'
require 'htmlentities'
require 'fastimage'
require 'rsolr'
require 'csv'

require 'portfolio_analyzer'
require 'portfolio_analyzer/mahara_accessor'

class AnalyzerController < ApplicationController
  attr_accessor :moodle_login_url
  attr_accessor :mahara_dashboard_url
  attr_accessor :username
  attr_accessor :password
  attr_accessor :mahara_accessor
  attr_accessor :mahara_dashboard_page
  attr_accessor :group_links
  attr_accessor :group_options
  attr_accessor :groupid
  attr_accessor :groupname
  attr_accessor :portfolio_download_dir
  attr_accessor :group_download_dir
  attr_accessor :overwrite
  attr_accessor :group_members
  attr_accessor :updated_members

  def start
  end

  def login
    @moodle_login_url = params[:moodle_login_url]
    @mahara_dashboard_url = params[:mahara_dashboard_url]
    @username = params[:username]
    @password = params[:password]

    @mahara_accessor = MaharaAccessor.new(@username, @password, @moodle_login_url, @mahara_dashboard_url)
    #session[:mahara_accessor] = @mahara_accessor
    #session[:agent] = @mahara_accessor.agent
    @mahara_dashboard_page = @mahara_accessor.open_mahara
    #session[:mahara_dashboard_page] = @mahara_dashboard_page

    if (@mahara_dashboard_page == nil) then
      raise ActionController::InvalidAuthenticityToken.new('Cannot login')
    end

    # save credentials in session to enable later access
    session[:moodle_login_url] = @moodle_login_url
    session[:mahara_dashboard_url] = @mahara_dashboard_url
    session[:username] = @username
    session[:password] = @password

    # show available groups
    @group_links = @mahara_accessor.extract_group_links
    # session[:group_links] = @group_links

    logger.debug "login: @group_links.length = #{@group_links.length}"
    id = 0
    @group_options = @group_links.map do |g|
      res = [g,id]
      id += 1
      res
    end

  end

  def analyze_group
    groupid = params[:groupid].to_i
    logger.debug "groupid: #{groupid}"

    # retrieve group_links once more ...
    # Remark: there seems to be no goodway to store these persistently in the ActionController. The ActionController
    # is stateless and will be newly created for each call. For this, attribute values will be forgotten. Approaches
    # to use the session cache or a Rails mem cache failed due to the fact that complex objects such as these links
    # (which are in fact of the type Nokogiri::XML::Element) lack an appropriate way for serialization ...
    username = session[:username]
    password = session[:password]
    moodle_login_url = session[:moodle_login_url]
    mahara_dashboard_url = session[:mahara_dashboard_url]
    mahara_accessor = MaharaAccessor.new(username, password, moodle_login_url, mahara_dashboard_url)
    mahara_dashboard_page = mahara_accessor.open_mahara
    raise ActionController::InvalidAuthenticityToken.new('Cannot login') unless (mahara_dashboard_page != nil)
    group_links = mahara_accessor.extract_group_links
    agent = mahara_accessor.agent

    # TODO
    download_images = true

    groupname = group_links[groupid].text
    grouplink = group_links[groupid].href

    logger.debug "groupname: #{groupname}"
    logger.debug "grouplink: #{grouplink}"

    session[:groupname] = groupname
    session[:grouplink] = grouplink

    portfolio_download_dir = Rails.configuration.portfolio_download_dir
    logger.debug "portfolio_download_dir: #{portfolio_download_dir}"

    group_download_dir = portfolio_download_dir + "/" + groupname.gsub(/\s/, '_')
    overwrite = true  #standard for the moment, behaviour might have to be changed in the future
    session[:portfolio_download_dir] = portfolio_download_dir
    session[:group_download_dir] = group_download_dir
    session[:overwrite] = overwrite

    logger.debug "group_download_dir: #{group_download_dir}"
    FileUtils::mkdir_p group_download_dir unless Dir.exists? group_download_dir or !overwrite
    logger.debug "group_download_dir created!"

    add_to_solr = params[:add_to_solr]
    solr_url = Rails.configuration.solr_url

    # connect to solr
    solr = nil
    solr = RSolr.connect :url => solr_url if (add_to_solr)
    if (solr == nil) then
      logger.warn "warning: connection to Solr could not be established: url = #{solr_url}"
    end

    # extract group members
    @group_members = mahara_accessor.extract_group_members(grouplink, groupname)
    logger.debug "extracted mumber of portfolio users: " + @group_members.length.to_s

    # add existing portfolios downloaded already
    PortfolioAnalyzer.read_user_config(group_download_dir).each do |user|
      @group_members.concat mahara_accessor.find_user(user)
    end

    @updated_members = []
    @group_members.each do |member|
      logger.debug "portfolios for member " + member.name
      config_available = false

      member_download_dir = group_download_dir + "/" + member.name.gsub(/\s/, '_')
      # create member download dir if necessary
      if (not Dir.exist? member_download_dir) then
        begin
          Dir.mkdir member_download_dir
        rescue Exception => e
          logger.warn "error creating download dir for member " + member.name + ": " + e.to_s
          next
        end
      elsif !overwrite
        # try to restore member state from JSON file
        begin
          member = MaharaMember.load(member_download_dir)
          logger.debug "Restored member " + member.name
          config_available = true unless member.portfolios == nil or member.portfolios.empty?
        rescue Exception => e
          logger.warn "Could not restore member " + member.name + ": " + e.to_s
        end
      end

      mahara_user_views_page = agent.get(member.mainlink)

      # find block containing
      portfolios_block = mahara_user_views_page.css('.bt-myviews')[0]
      if (portfolios_block == nil) then
        logger.warn "WARNING: portfolio view block '#{member.name}\'s Portfolios' not found on member's dashboard page"
        logger.warn "Unable to extract portfolio view list!"
        next
      end

      portfolio_views = []
      i = 0
      views_download_dir = member_download_dir + "/views"
      FileUtils::mkdir_p views_download_dir unless Dir.exists? views_download_dir or !overwrite
      img_download_dir = member_download_dir + "/uploaded_images"
      # save uploaded_images first ... to adapt the documents image URLs to the local path
      FileUtils::mkdir_p img_download_dir unless Dir.exists? img_download_dir or !overwrite

      portfolios_block.css('a.outer-link').each do |a|
        portfolio_name = a.text.strip
        include_portfolio = false
        # use existing configuration if available
        if config_available
          include_portfolio = member.portfolios.include?(portfolio_name)
        else
          # TODO: provide support for individual portfolios
          include_portfolio = true
          # update member settings depending on user input
          member.portfolios << portfolio_name if include_portfolio
        end

        if include_portfolio
          portfolio_view = mahara_accessor.get_portfolio_view member, portfolio_name, a['href']
          portfolio_views << portfolio_view

          # localy save the portfolio for possible further processing
          logger.debug "saving view '#{portfolio_view.title}' for member #{member.name} ..."
          view_download_path = views_download_dir + "/" + "view#{i}.html"

          PortfolioAnalyzer.handle_view_images(img_download_dir, mahara_accessor, portfolio_view) if download_images

          # now saving view
          portfolio_view.save mahara_accessor.agent, view_download_path
          # instead, we should do something like:
          # save nokogiri_doc.to_html
          # since the Mechanize based save method of the portfolio view does not recognize changes
          # made on the nokogiti doc level ...

          # add to Solr
          PortfolioAnalyzer.add_to_solr(member, portfolio_view, solr)

          # check for further views attached to this one
          if mahara_accessor.has_more_views? portfolio_view then
            logger.debug "processing additional views found for view '#{portfolio_view.title}' for user '#{member.name}'"
            mahara_accessor.subsequent_views(portfolio_view).each do |link|
              logger.debug "processing view #{link}"
              next_portfolio_view = mahara_accessor.get_portfolio_view(member, portfolio_view.portfolio_title + " - View 2", link)

              portfolio_views << next_portfolio_view

              # localy save the portfolio for possible further processing
              logger.debug "saving view '#{next_portfolio_view.title}' for member #{member.name} ..."
              i = i + 1
              view_download_path = views_download_dir + "/" + "view#{i}.html"

              PortfolioAnalyzer.handle_view_images(img_download_dir, mahara_accessor, next_portfolio_view) if download_images

              # now saving view
              next_portfolio_view.save mahara_accessor.agent, view_download_path

              # add to Solr
              PortfolioAnalyzer.add_to_solr(member, next_portfolio_view, solr)
            end
          end

          i = i + 1
        end
      end

      member.views = portfolio_views
      member.save member_download_dir
      @updated_members << member
      #end
    end

    # create CSV table summarizing everything we found so far
    csv_summary_filename = group_download_dir + "/" + CSV_SUMMARY_FILE_NAME
    begin
      CSV.open(csv_summary_filename, "wb", {:col_sep => ";"}) do |csv|
        csv << ["Nummer", "Name", "# Views"]
        i = 1
        @updated_members.each do |member|
          csv << [i, member.name, member.views.length]
          i = i + 1
        end
      end
    rescue Exception => e
      logger.warn "ERROR: could not write CSV summary file to '#{csv_summary_filename}'"
    end

  end

end
