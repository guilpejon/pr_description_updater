#!/usr/bin/env ruby
# frozen_string_literal: true

require 'octokit'
require 'jira-ruby'

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
    jiras << commit.commit.message.scan(/(\w+-\d+)/).flatten[0]&.strip
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
  @open_jiras = []
  @jiras_with_deploy_notes = []
  @parent_tags = []

  def extract_jira_info(jira, subtasks = nil)
    print "\e[1;32m.\e[0m"

    jira_status = jira.status.name
    jira_tag = jira.key

    if jira_status == 'Closed'
      @closed_jiras << "#### [#{jira_tag}] #{jira.summary.rstrip}"
    else
      @open_jiras << "#### [#{jira_tag}] (#{jira_status})\n**Title:** #{jira.summary.rstrip}\n#{"**Subtasks:** #{subtasks.join(', ')}" if subtasks.present?}"
    end

    # customfield_10033 is the field id of the 'Deploy Notes' field
    if jira.customfield_10033.present? && jira.customfield_10033 != 'Not Required'
      deploy_notes_parsed = jira.customfield_10033
                                .gsub('{code}', "\n```\n")
                                .gsub('{{', '`')
                                .gsub('}}', '`')
                                .gsub('*', '**')
                                .gsub('{code:ruby}', "```ruby\n")
                                .gsub('h4.', '####')
                                .to_s
      @jiras_with_deploy_notes << "#### [#{jira_tag}] #{jira.summary.rstrip} \n #{deploy_notes_parsed}"
    end

    @pr_footer << "[#{jira_tag}]: https://#{ENV['JIRA_COMPANY_NAME']}.atlassian.net/browse/#{jira_tag}"
  end

  jiras.sort.each do |jira_tag|
    begin
      jira = jira_client.Issue.find(jira_tag)

      # Save parent jiras to use later
      @parent_tags << jira.parent['key'] if jira.try(:parent).present?

      extract_jira_info(jira)
    rescue StandardError
      puts "JIRA #{jira_tag} não encontrado"
    end
  end

  # Extract parent and write it with its subtasks
  @parent_tags.uniq.each do |jira_tag|
    jira = jira_client.Issue.find(jira_tag)
    subtasks = jira.subtasks.map { |j| "[#{j['key']}] (#{j['fields']['status']['name']})" }
    extract_jira_info(jira, subtasks)
    subtasks.each do |tag|
      @pr_footer << "#{tag.split(' ').first}: https://#{ENV['JIRA_COMPANY_NAME']}.atlassian.net/browse/#{tag.gsub(/\[|\]/, '').split(' ').first}"
    end
  end

  pr_body = "#{"# OPEN (#{@open_jiras.count})\n" if @open_jiras.present?}" \
    "#{@open_jiras.join("\n") if @open_jiras.present?}" \
    "#{"\n# CLOSED (#{@closed_jiras.count})\n" if @closed_jiras.present?}" \
    "#{@closed_jiras.join("\n") if @closed_jiras.present?}" \
    "#{"\n# DEPLOY NOTES\n" if @jiras_with_deploy_notes.present?}" \
    "#{@jiras_with_deploy_notes.join("\n") if @jiras_with_deploy_notes.present?}" \
    "\n\n" \
    "#{@pr_footer.join("\n")}"

  gh_client.update_pull_request(repo.id, release_pr.number, body: pr_body)
end

puts
