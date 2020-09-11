fs = require 'fs-plus'
cp = require 'child_process'
tmp = require 'tmp'
path = require 'path'

Parser = require 'web-tree-sitter'
parser = undefined

# while the Parser is initializing and loading the language, we block its use
Parser.init().then () =>
  Parser.Language.load(path.join __dirname,'./tree-sitter-hit.wasm').then (lang) =>
    parser = new Parser();
    parser.setLanguage(lang);

mooseApp = /^(.*)-(opt|dbg|oprof|devel)$/
appDirs = {}

module.exports =
  config:
    fallbackMooseDir:
      type: 'string'
      default: ''
      description: 'If no MOOSE executable is found in or above the current directory, search here instead.'

  activate: ->
    atom.commands.add 'atom-workspace', 'action-explode-moose:explode', => @explode()

  # determine the active input file path at the current position
  getCurrentConfigPath: (editor, tree) ->
    position = editor.getCursorBufferPosition()

    recurseCurrentConfigPath = (node, sourcePath = []) ->
      for c in node.children
        if c.type != 'top_block' && c.type != 'block'
          continue

        # check if we are inside a block or top_block
        cs = c.startPosition
        ce = c.endPosition

        # outside row range
        if position.row < cs.row || position.row > ce.row
          continue

        # in starting row but before starting column
        if position.row == cs.row && position.column < cs.column
          continue

        # in ending row but after ending column
        if position.row == ce.row && position.column > ce.column
          continue

        # if the block does not contain a valid path subnode we give up
        if c.children.length < 2 || c.children[1].type != 'block_path'
          return [node.parent, sourcePath]

        # first block_path node
        if c.children[1].startPosition.row >= position.row
          continue

        return recurseCurrentConfigPath c, sourcePath.concat(c.children[1].text.replace(/^\.\//, '').split('/'))

      return [node, sourcePath]

    recurseCurrentConfigPath tree.rootNode

  findApp: (filePath) ->
    if not filePath?
      atom.notifications.addError 'File not saved, nowhere to search for MOOSE syntax data.', dismissable: true
      return null

    if filePath of appDirs
      return appDirs[filePath]

    searchPath = filePath
    matches = []
    loop
      # list all files
      for file in fs.readdirSync(searchPath)
        match = mooseApp.exec(file)
        if match
          fileWithPath = path.join searchPath, file
          continue if not fs.isExecutableSync fileWithPath
          matches.push {
            appPath: searchPath
            appName: match[1]
            appFile: fileWithPath
            appDate: fs.statSync(fileWithPath).mtime.getTime()
          }

      if matches.length > 0
        # return newest application
        matches.sort (a, b) ->
          b.appDate - a.appDate

        appDirs[filePath] = matches[0]
        return appDirs[filePath]

      # go to parent
      previous_path = searchPath
      searchPath = path.join searchPath, '..'

      if searchPath is previous_path
        # no executable found, let's check the fallback path
        fallbackMooseDir = atom.config.get "autocomplete-moose.fallbackMooseDir"
        if fallbackMooseDir != '' and filePath != fallbackMooseDir
          return @findApp fallbackMooseDir

        # otherwise pop up an error notification (if not disabled) end give up
        atom.notifications.addError 'No MOOSE application executable found.', dismissable: true \
          unless  atom.config.get "autocomplete-moose.ignoreMooseNotFoundError"
        return null

  explode: ->
    # Check if the active item is a text editor
    editor = atom.workspace.getActiveTextEditor()
    return unless editor?

    # parse the editor contents as hit
    return unless parser?
    tree = parser.parse editor.getBuffer().getText()

    # lookup application for current input file (cached)
    filePath = path.dirname editor.getPath()
    {appPath, appName, appFile, appDate} = @findApp filePath
    console.log appPath, appName, appFile, appDate

    # open notification about syntax generation
    workingNotification = atom.notifications.addInfo 'Resolving MOOSE action syntax. Do not edit file!', {dismissable: true}

    # get block path
    [node, sourcePath] = @getCurrentConfigPath(editor, tree)

    # no path -> don't bother running the executable
    if sourcePath.length == 0
      workingNotification.dismiss()
      return

    # save current file to a temporary
    tmp.file (err, path, fd) =>
      if err
        workingNotification.dismiss()
        atom.notifications.addError 'Failed to create temporary file.', dismissable: true
        return

      # write file
      fs.writeFile path, editor.getBuffer().getText(), (err) =>
        if err
          workingNotification.dismiss()
          atom.notifications.addError 'Failed to write temporary file.', dismissable: true
          return

        # run MOOSE app with DumpObjectsProblem
        mooseDOP = new Promise (resolve, reject) ->
          console.log 'running', appFile
          console.log [appFile, '-i', editor.getPath(), "Problem/type=DumpObjectsProblem", "Problem/dump_path=#{sourcePath.join '/'}"].join(' ')

          cp.execFile appFile, ['-i', path, "Problem/type=DumpObjectsProblem", "Problem/dump_path=#{sourcePath.join '/'}"], (error, stdout, stderr) ->
            resolve stdout.toString()

        .then (result) ->
          beginMarker = '**START DUMP DATA**\n'
          endMarker = '**END DUMP DATA**\n'
          begin = result.indexOf beginMarker
          end= result.lastIndexOf endMarker

          throw 'Malformed input file.' if begin < 0 or end < begin
          workingNotification.dismiss()

          result[begin+beginMarker.length..end-1]

        .then (result) ->
          # reparse tree to determine insertion site
          # parser.parseTextBuffer(editor.getBuffer().buffer).then (tree) =>
          #   # locate sourcePath in the tree again (the user may have edited in teh time it took to resolve the action)
          #   node = tree.rootNode
          #   for b in sourcePath
          #     console.log b
          #   #console.log 'reparsed', result, tree

          # find toplevel block node
          top_node = node
          while top_node != null and top_node.type != 'top_block'
            top_node = top_node.parent
          throw 'Unable to find top node' unless top_node?

          console.log node, top_node

          # and insert expanded syntax after it
          editor.getBuffer().insert [top_node.endPosition.row, top_node.endPosition.column], '\n\n' + result

          # delete original action (sub)block
          editor.getBuffer().delete [[node.startPosition.row, node.startPosition.column],
                                     [node.endPosition.row, node.endPosition.column]]


        .catch (error) ->
          console.log error
          workingNotification.dismiss()
          atom.notifications.addError "Unable to resolve action syntax. '#{error}'", dismissable: true
