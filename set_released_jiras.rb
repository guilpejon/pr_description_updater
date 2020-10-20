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
  release_pr = gh_client.pull_request("#{ENV['GITHUB_COMPANY_NAME']}/#{project_name}", pr_number) # , state: 'closed')

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
  # Change JIRAs statuses to release
  ####

  jiras.sort.each do |jira_tag|
    next if jira_tag.include?("BAB") || jira_tag.include?("IMPL")
    jira = jira_client.Issue.find(jira_tag)
    # available_transitions = jira_client.Transition.all(issue: jira)
    # available_transitions.each { |ea| puts "#{ea.name} (id #{ea.id})" }

    jira_status = jira.status.name
    if jira_status.downcase == 'acceptance' || jira_status.downcase == 'done' || jira_status.downcase == 'ready-for-release'
      jira.transitions.build.save!('transition' => { 'id' => '51' })
      puts "RELEASED issue #{jira.key}"
    end
  rescue StandardError => e
    puts e
    # puts e.backtrace.join("\n")
    # puts "JIRA #{jira_tag} não encontrado"
  end
end
