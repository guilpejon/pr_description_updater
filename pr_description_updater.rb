#!/usr/bin/env ruby
# frozen_string_literal: true

require 'octokit'
require 'jira-ruby'
require 'byebug'

####
# CHECK IF PROJECT NAME AND PR NUMBER WERE SENT
####

if ARGV.empty?
  puts '>> Add the project names and the PR numbers to the script call'
  puts '>> "project_name pr_number,project_name pr_number"'
  exit
else
  args = ARGV[0]
end

####
# CONNECT TO GITHUB API
####

gh_client = Octokit::Client.new(access_token: ENV['GITHUB_TOKEN'])
gh_client.auto_paginate = true

user = gh_client.user
user.login

args.split(',').each do |arg|
  project_name, pr_number = arg.split(' ')
  pr_number = pr_number.to_i

  puts "\n>> Fetching #{project_name} - #{pr_number}"

  ####
  # GRAB JIRA NUMBERS FROM THE COMMITS OF THE PR
  ####

  repo = gh_client.repos.select { |repository| repository.name == project_name }[0]
  pull_requests = gh_client.pull_requests "#{ENV['GITHUB_COMPANY_NAME']}/#{project_name}"
  release_pr = pull_requests.select { |pr| pr[:number] == pr_number }[0]

  commits = gh_client.pull_request_commits(repo.id, release_pr.number)

  jiras = []
  commits.each do |commit|
    commit_title = commit.commit.message.split("\n").first
    jira_codes = commit_title.scan(/[\[|\(][A-Z]*-\d*[\]|\)]/)
    jira_codes.each do |j|
      jiras << j[1..-2]&.strip
    end
  end

  jiras = jiras.reject(&:nil?).map(&:upcase).uniq

  ####
  # CONNECT TO JIRA API
  ####

  jira_username = ENV['JIRA_USERNAME']
  jira_api_token = ENV['JIRA_TOKEN']

  options = {
    username: jira_username,
    password: jira_api_token,
    site: "https://#{ENV['JIRA_COMPANY_NAME']}.atlassian.net",
    context_path: '',
    auth_type: :basic,
    read_timeout: 120
  }

  jira_client = JIRA::Client.new(options)

  ####
  # FORMAT TEXT AND WRITE TO PR BODY
  ####

  @pr_footer = []
  @closed_jiras = []
  @in_acceptance_jiras = []
  @released_jiras = []
  @open_jiras = []
  @jiras_with_deploy_notes = []
  @parent_tags = []

  def parse_deploy_notes(deploy_notes_field)
    return '' unless deploy_notes_field

    deploy_notes_field
      .gsub('{code}', "\n```\n")
      .gsub('{{', '`')
      .gsub('{noformat}', "\n```\n")
      .gsub('}}', '`')
      .gsub('*', '**')
      .gsub('{code:ruby}', "```ruby\n")
      .gsub('h4.', '####')
      .to_s
  end

  def extract_jira_info(jira, subtasks = nil)
    print "\e[1;32m.\e[0m"

    jira_status = jira.status.name
    jira_tag = jira.key

    if jira_status == 'RELEASE' || jira_status == 'Release'
      @released_jiras << "#### [#{jira_tag}] #{jira.summary.rstrip}"
    else
      if jira_status == 'Closed' || jira_status == 'DONE' || jira_status == 'Done'
        @closed_jiras << "#### [#{jira_tag}] #{jira.summary.rstrip}"
      elsif jira_status == 'Acceptance' || jira_status == 'ACCEPTANCE'
        @in_acceptance_jiras << "#### [#{jira_tag}] #{jira.summary.rstrip}"
      else
        @open_jiras << "#### [#{jira_tag}] (#{jira_status})\n**Title:** #{jira.summary.rstrip}\n#{if subtasks.present?
                                                                                                    "**Subtasks:** #{subtasks.join(', ')}"
                                                                                                  end}"
      end
      # customfield_XXXXX is the field id of the 'Deploy Notes' field
      if jira.issuetype.name != 'Epic'
        if jira.key.include?('SER') && jira.customfield_10033.present? && jira.customfield_10033 != 'Not Required'
          deploy_notes_parsed = parse_deploy_notes(jira.customfield_10033)
          @jiras_with_deploy_notes << "#### [#{jira_tag}] #{jira.summary.rstrip} \n #{deploy_notes_parsed}"
        elsif jira.key.include?('EGIP') && jira.customfield_10054.present?
          deploy_notes_parsed = parse_deploy_notes(jira.customfield_10054)
          if deploy_notes_parsed
            @jiras_with_deploy_notes << "#### [#{jira_tag}] #{jira.summary.rstrip} \n #{deploy_notes_parsed}"
          end
        elsif jira.key.include?('ATLAN') && jira.customfield_10057.present?
          deploy_notes_parsed = parse_deploy_notes(jira.customfield_10057)
          if deploy_notes_parsed
            @jiras_with_deploy_notes << "#### [#{jira_tag}] #{jira.summary.rstrip} \n #{deploy_notes_parsed}"
          end
        end
      end
    end

    @pr_footer << "[#{jira_tag}]: https://#{ENV['JIRA_COMPANY_NAME']}.atlassian.net/browse/#{jira_tag}"
  end

  jiras.sort.each do |jira_tag|
    jira = jira_client.Issue.find(jira_tag)
    # available_transitions = jira_client.Transition.all(issue: jira)
    # available_transitions.each { |ea| puts "#{ea.name} (id #{ea.id})" }

    jira_status = jira.status.name
    if jira_status == 'Code Owner Review' || jira_status == 'CODE OWNER REVIEW'
      jira.transitions.build.save!('transition' => { 'id' => '121' })
      # jira.transitions.build.save!('transition' => { 'id' => '81' })
      jira = jira_client.Issue.find(jira_tag)
      puts "Resolved issue #{jira.key}"
    elsif jira_status == 'Pending Merge' || jira_status == 'PENDING MERGE'
      jira.transitions.build.save!('transition' => { 'id' => '121' })
      jira = jira_client.Issue.find(jira_tag)
      puts "Resolved issue #{jira.key}"
    end

    # Save parent jiras to use later
    @parent_tags << jira.parent['key'] if jira.try(:parent).present?

    extract_jira_info(jira)
  rescue StandardError => e
    puts e
    # puts e.backtrace.join("\n")
    # puts "JIRA #{jira_tag} não encontrado"
  end

  # Extract parent and write it with its subtasks
  # @parent_tags.uniq.each do |jira_tag|
  #   jira = jira_client.Issue.find(jira_tag)
  #   subtasks = jira.subtasks.map { |j| "[#{j['key']}] (#{j['fields']['status']['name']})" }
  #   extract_jira_info(jira, subtasks)
  #   subtasks.each do |tag|
  #     @pr_footer << "#{tag.split(' ').first}: https://#{ENV['JIRA_COMPANY_NAME']}.atlassian.net/browse/#{tag.gsub(/\[|\]/, '').split(' ').first}"
  #   end
  # end

  pr_body = "#{"# OPEN (#{@open_jiras.count})\n" if @open_jiras.present?}" \
    "#{@open_jiras.join("\n") if @open_jiras.present?}" \
    "#{if @in_acceptance_jiras.present?
         "\n# ACCEPTANCE (#{@in_acceptance_jiras.count})\n"
       end}" \
    "#{@in_acceptance_jiras.join("\n") if @in_acceptance_jiras.present?}" \
    "#{"\n# CLOSED (#{@closed_jiras.count})\n" if @closed_jiras.present?}" \
    "#{@closed_jiras.join("\n") if @closed_jiras.present?}" \
    "#{if @released_jiras.present?
         "\n# RELEASED (#{@released_jiras.count})\n"
       end}" \
    "#{@released_jiras.join("\n") if @released_jiras.present?}" \
    "#{"\n# DEPLOY NOTES\n" if @jiras_with_deploy_notes.present?}" \
    "#{if @jiras_with_deploy_notes.present?
         @jiras_with_deploy_notes.join("\n")
       end}" \
    "\n\n" \
    "#{@pr_footer.join("\n")}"

  gh_client.update_pull_request(repo.id, release_pr.number, body: pr_body)
end
