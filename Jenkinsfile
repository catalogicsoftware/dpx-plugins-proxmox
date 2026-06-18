@Library('dpx-jenkins-pipeline-library@master') _

withCommonNodeOptions('docker', 1) {
    runCheckout()

    if (env.BRANCH_NAME in constants.semanticReleaseBranches) {
        runSemanticRelease()
    } else if (env.TAG_NAME) {
        runUpdateFileVariable(
            gitRepo: constants.pluginsProxmoxInternalGitRepo
            variableName: constants.publicProxmoxPluginVersionVariableName,
            newVariableValue: env.TAG_NAME,
        )
    }
}
