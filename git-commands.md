# Git Commands

- To add a GitHub repo as a subtree for personal GitHub website, use 
  ```
  git subtree add --prefix=reponame https://github.com/aaronamran/RepoName.git main --squash
  ```
  pull current updates of a repo and reflect it on personal GitHub website, use
  ```
  git subtree pull --prefix=reponame https://github.com/aaronamran/RepoName.git main --squash
  ```
  then use
  ```
  git push origin main
  ```
