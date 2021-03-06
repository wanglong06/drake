.. _faq:

**************************
Frequently Asked Questions
**************************

..warning::

    This page is old. Please review :ref:`getting_help` for more up-to-date
    information.

.. contents:: `Table of contents`
   :depth: 3
   :local:

.. _faq_vmware:

Why doesn't Drake Visualizer work in VMWare Fusion or Workstation?
==================================================================

**Symptom**: The simulation runs and the visualization window appears, but no
objects are actually drawn. This appeared to be due to display drivers and/or
non support of hardware-accelerated rendering. To address this, go to
``Virtual Machine Settings``, and check the ``Accelerate 3D Graphics`` box under
Display settings; now the simulations draw properly.

.. _faq_opengl_test:

Why do OpenGL-based VTK targets run with ``bazel test`` sometimes fail on Linux?
================================================================================

**Symptom**: While the binary works with ``bazel run``, when you run a test using ``bazel test``, such as::

    $ bazel test //systems/sensors:rgbd_camera_test

you encounter a slew of errors from VTK / OpenGL::

    ERROR: In /vtk/Rendering/OpenGL2/vtkXOpenGLRenderWindow.cxx, line 820
    vtkXOpenGLRenderWindow (0x55880715b760): failed to create offscreen window

    ERROR: In /vtk/Rendering/OpenGL2/vtkOpenGLRenderWindow.cxx, line 816
    vtkXOpenGLRenderWindow (0x55880715b760): GLEW could not be initialized.

    ERROR: In /vtk/Rendering/OpenGL2/vtkShaderProgram.cxx, line 453
    vtkShaderProgram (0x5588071d5aa0): Shader object was not initialized, cannot attach it.

    ERROR: In /vtk/Rendering/OpenGL2/vtkOpenGLRenderWindow.cxx, line 1858
    vtkXOpenGLRenderWindow (0x55880715b760): Hardware does not support the number of textures defined.

**Solution**: The best workaround is to first mark the test as as `local <https://docs.bazel.build/versions/master/be/general.html#genrule.local>`_ in the ``BUILD`` file, either
with ``local = 1``, or ``tags = [.., "local"],``. Doing so will make the specific target run without sandboxing, such that it has an environment similar to that of ``bazel run``.

As an example, in ``drake/systems/sensors/BUILD``::

    drake_cc_googletest(
        name = "rgbd_camera_test",
        # ...
        local = 1,
        # ...
    )

If this does not work, then try running the test in Bazel without sandboxing::

    $ bazel test --spawn_strategy=standalone //systems/sensors:rgbd_camera_test

Please note that you can possibly add ``--spawn_strategy=standalone`` to your ``~/.bazelrc``, but be aware that this means your development machine
may have a different environment than other development machines when running the test.

.. _faq_gcc_4_9:

Why do I get linker errors when I build a CMake project using Drake, but I can clearly see the symbols?
=======================================================================================================

**Symptom**: You have followed one of the options in the :ref:`installation_and_quick_start` instructions, and are writing a CMake project to use Drake.

You look at a unittest that builds in Drake, run it, and it builds, runs, and passes. However, when you try to use some of that functionality in your CMake project, you get a linker error, such as::

    undefined reference to `RigidBodyTree<double>::get_position_name(int) const'

If you look at symbols in the Drake shared library (e.g. ``nm -C`` or ``objdump -TC`` with ``grep``), you see the signature ``RigidBodyTree<double>::get_position_name[abi:cxx11](int)``. However, if you look in the produced object code (which causes the linking to fail), you see ``RigidBodyTree<double>::get_position_name(int)``.

**Solution**: This is most likely due to an incompatibilty between the compiler used to produce Drake (e.g. ``clang``) and the compiler that CMake has selected (e.g. ``gcc-4.9``). Specifically, ``gcc-4.9`` or before does not tend to handle the DualABI well when linking against ``clang``-compiled code [#dual_abi]_. You may be able to use other functions, because only functions that return an ABI-dependent class (e.g. ``std::string``) are tagged with the ABI that they are using (since they cannot be distinguished in the function signature).

The fix is to change the compiler CMake is using. One way to do this is to set the ``CC`` and ``CXX`` environment variables to use a supported compiler. For a list of supported compilers, see :ref:`supported-configurations`. If you are using pre-compiled binaries [#binary_install]_, please refer to the :ref:`binary-packages` for the compilers used.

.. note::

    Do not change the compiler using ``update-alternatives`` in Ubuntu, as this may affect your DKMS module compatibility with the kernel (among other things) [#update_alt]_.

.. [#dual_abi] https://stackoverflow.com/q/36159238/7829525
.. [#binary_install] :ref:`binary-installation`
.. [#update_alt] https://askubuntu.com/a/26500/692420
