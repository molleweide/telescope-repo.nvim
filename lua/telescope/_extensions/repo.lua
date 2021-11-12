local repo_builtin = require'telescope._extensions.repo_builtin'

print("local telescope repo")

return require'telescope'.register_extension{
  exports = {
    list = repo_builtin.list,
    cached_list = repo_builtin.cached_list,
  },
}
