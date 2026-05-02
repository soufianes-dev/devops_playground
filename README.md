# DevOps Playground

`git config --list --global`
`rm -f ~/.gitconfig` before starting

Load .env file
`set -a` Marks all variables for export
`source .env` Load the file
`set +a` Turns off automatic export

`bash .github/scripts/release.sh`

<https://www.simplilearn.com/what-is-git-rebase-command-article>
<https://github.com/soufianes-dev/devops_playground/actions/workflows/ci.yml>

## Git Recipes

**_Recipe0_**

Delete all previous commits (start completely fresh)

```bash
# Delete remote tags
git push --delete origin $(git tag -l)
# Delete all local tags
git tag -d $(git tag)
# Create a new orphan branch
git checkout --orphan temp_branch
git add .
git commit -m "initial commit"
# Replace the main branch
git branch -M temp_branch main
git push origin +main # Force push
# Clean up local repository
git remote prune origin
```

**_Recipe1_**

```bash
# Fork and Clone the repository
git clone https://github.com/soufianes-dev/Spoon-Knife.git
cd spoon_knife
# Create and switch to the new branch
# `git checkout main` to switch to the main branch
git checkout -b feature/some-feature
# Get current branch
git branch
code .
# Make changes in the new branch `feature/some-feature`
# git add . | git add -all | git add file.extension
git add .
# Check the status of all the files we changed
git status
# Commit the changes
git commit -m "your commit message"
# Publish changes to the remote repository
git push origin feature/some-feature
# If pull request PR merged successfully then delete that branch
# For local repo
git branch -d feature/some-feature
# For remote repo
git push origin --delete feature/some-feature
```

**_Recipe2_**

```bash
git init
git add .
git commit -m "first commit [no ci]"
git branch -M main
git remote add origin https://github.com/soufianes-dev/devops_playground.git
git push -u origin main
```

**_Recipe3_**

```bash
# Rename branch locally
git branch -m master main

```

**_Recipe4_**

```bash
# Clear file1.txt (clear by redirecting nothing to the file)
> src/file1.txt
echo "initial feature" > src/file1.txt
# NOTE: Update version in config.yml with 0.1.0
# Clear CHANGELOG.md
> CHANGELOG.md

# Delete all previous commits (start completely fresh) (Recipe)
git push --delete origin $(git tag -l) # Delete remote tags
git tag -d $(git tag) # Delete all local tags
# Create a new orphan branch
git checkout --orphan temp_branch
git add .
git commit -m "initial commit" # git commit -m "initial commit" -m "Pre-Release: dev"
# Replace the main branch
git branch -M temp_branch main
git push origin +main # Force push
# Clean up local repository
git remote prune origin
```
