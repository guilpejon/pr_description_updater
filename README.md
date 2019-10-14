# Setup
Create a `.env` file filling the following variables:

```ruby
export JIRA_USERNAME=''
export JIRA_TOKEN=''
export GITHUB_TOKEN=''
export JIRA_COMPANY_NAME=''
export GITHUB_COMPANY_NAME=''
```

Run `source .env` once.

# Running
```ruby
  ruby pr_description_updater.rb "repo_name pr_id,repo_name_2 pr_id_2"
```
