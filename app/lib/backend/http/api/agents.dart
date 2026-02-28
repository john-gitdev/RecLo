import 'dart:convert';

import 'package:reclo/backend/http/shared.dart';
import 'package:reclo/backend/schema/agent.dart';
import 'package:reclo/env/env.dart';
import 'package:reclo/utils/logger.dart';

Future<AgentVmInfo?> getAgentVmStatus() async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/agent/vm-status',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return null;
  if (response.statusCode == 200) {
    return AgentVmInfo.fromJson(jsonDecode(response.body));
  }
  return null;
}

Future<void> ensureAgentVm() async {
  try {
    await makeApiCall(
      url: '${Env.apiBaseUrl}v1/agent/vm-ensure',
      headers: {},
      method: 'POST',
      body: '',
    );
  } catch (e) {
    Logger.debug('ensureAgentVm failed: $e');
  }
}

Future<void> sendAgentKeepalive() async {
  try {
    await makeApiCall(
      url: '${Env.apiBaseUrl}v1/agent/keepalive',
      headers: {},
      method: 'POST',
      body: '',
    );
  } catch (e) {
    Logger.debug('sendAgentKeepalive failed: $e');
  }
}
